#!/bin/bash
set -u

export OPENVPN_CONFIG_DIR=${OPENVPN_CONFIG_DIR:-"/etc/openvpn"}
export OPENVPN_KEYS_DIR=${OPENVPN_KEYS_DIR:-"/etc/openvpn/keys"}

function clean {
	echo -n "Cleaning the openvpn config directory: $OPENVPN_CONFIG_DIR..."
	rm -Rf $OPENVPN_CONFIG_DIR
	mkdir $OPENVPN_CONFIG_DIR 2> /dev/null
	echo "OK"
}

function fail {
	echo $1
	exit 1
}

function create_ca {

	if (( $# != 1 )); then
		echo "Failed to create ca."
		echo "usage: create_ca <ca common name>"
		exit 1
	fi

	local CA_COMMON_NAME=$1

	echo -n "Copying easy-rsa into openvpn config dir..."
	local EASY_RSA_LOC=""

	if [ -f /etc/redhat-release ]; then
		EASY_RSA_LOC=$(rpm -qil openvpn | grep build-ca | tail -n 1)
	elif [ -f /etc/debian_version ]; then
		EASY_RSA_LOC=$(dpkg -L openvpn | grep build-ca | grep "2.0" | tail -n 1)
	else
		echo "Failed to locate openvpn 'build-ca'."
		return 1
	fi

	EASY_RSA_LOC=$(dirname $EASY_RSA_LOC)
	cd $OPENVPN_CONFIG_DIR
	cp -a $EASY_RSA_LOC $OPENVPN_CONFIG_DIR/easy-rsa || \
		fail "Failed to copy easy-rsa."
	echo "OK"

	# remove WARNING echo from vars file
	sed -e "s|^echo NOTE.*||g" -i $OPENVPN_CONFIG_DIR/easy-rsa/vars

	echo -n "Customizing vars file..."
	cat >> $OPENVPN_CONFIG_DIR/easy-rsa/vars <<-EOF_CAT
	export KEY_COUNTRY="US"
	export KEY_PROVINCE="VA"
	export KEY_CITY="Blacksburg"
	export KEY_ORG="Rackspace"
	export KEY_EMAIL="cobra@snakeoil.com"
	export KEY_OU="Infrastructure"
	#export KEY_CN="$CA_COMMON_NAME"
	export KEY_NAME="$CA_COMMON_NAME"
	export KEY_DIR="$OPENVPN_KEYS_DIR"
	EOF_CAT
	[[ $? == 0 ]] || fail "Failed to append to vars file."
	echo "OK"

	echo -n "Creating CA key for: $CA_COMMON_NAME..."
	cd $OPENVPN_CONFIG_DIR/easy-rsa
	bash <<-EOF_BASH
		. ./vars
		./clean-all &> /dev/null
		./pkitool --initca $CA_COMMON_NAME &> /dev/null
	EOF_BASH
	[[ $? == 0 ]] || fail "Failed to create CA keys."
	echo "OK"

}


function create_server_key {

	if (( $# != 1 )); then
		echo "Failed to create server key."
		echo "usage: create_server_key <server key name>"
		exit 1
	fi

	local SERVER_KEY_NAME=$1

	echo "Creating server key for: $SERVER_KEY_NAME."
	cd $OPENVPN_CONFIG_DIR/easy-rsa
	echo -n "Generating DH parameters (wait on it)..."
	bash <<-EOF_BASH
		. ./vars
		./pkitool --server $SERVER_KEY_NAME &> /dev/null
		./build-dh 2> /dev/null
	EOF_BASH
	[[ $? == 0 ]] || fail "Failed to create server key: $SERVER_KEY_NAME."
	echo "OK"

}

function create_client_key {

	if (( $# != 4 )); then
		echo "Failed to create client key."
		echo "usage: create_client_key <client name> <client ip> <client pptp ip>"
		exit 1
	fi

	local CLIENT_NAME=$1
	local CLIENT_DOMAIN=$2
	local CLIENT_INTERNAL_IP=$3
	local CLIENT_INTERNAL_PTP_IP=$4

	echo -n "Creating client key for: $CLIENT_NAME..."
	cd $OPENVPN_CONFIG_DIR/easy-rsa
	bash <<-EOF_BASH
		. ./vars
		./pkitool $CLIENT_NAME &> /dev/null
	EOF_BASH
	[[ $? == 0 ]] || fail "Failed to create client key: $CLIENT_NAME."
	echo "OK"

	TMP_DIR_CLIENT=$(mktemp -d)
	cd $TMP_DIR_CLIENT
	cp $OPENVPN_KEYS_DIR/ca.crt .  || fail "Failed to copy QA cert."
	cp $OPENVPN_KEYS_DIR/$CLIENT_NAME.crt . || fail "Failed to copy client cert."
	cp $OPENVPN_KEYS_DIR/$CLIENT_NAME.key . || fail "Failed to copy client key"
	tar czf $CLIENT_NAME.tar.gz * || fail "Failed to create client key tarball."
	mv $CLIENT_NAME.tar.gz $OPENVPN_KEYS_DIR
	cd - > /dev/null
	rm -Rf $TMP_DIR_CLIENT

	mkdir -p "$OPENVPN_CONFIG_DIR/ccd/" 2> /dev/null
	cat > $OPENVPN_CONFIG_DIR/ccd/$CLIENT_NAME <<-EOF_CAT
		ifconfig-push $CLIENT_INTERNAL_IP $CLIENT_INTERNAL_PTP_IP
	EOF_CAT

	# add the client name to /etc/hosts

	if ! grep "$CLIENT_INTERNAL_IP" /etc/hosts > /dev/null; then
		echo "$CLIENT_INTERNAL_IP	$CLIENT_NAME.$CLIENT_DOMAIN $CLIENT_NAME" >> /etc/hosts
	fi

	/etc/init.d/dnsmasq reload || /etc/init.d/dnsmasq restart

}

function start_dns_server {

	if [ -f /bin/rpm ]; then
		if ! rpm -q dnsmasq &> /dev/null; then
			yum install -y dnsmasq
		fi
	elif [ -f /usr/bin/dpkg ]; then
		if ! dpkg -s dnsmasq > /dev/null 2>&1; then
			aptitude install -y -q dnsmasq
		fi
	else
		echo "Unable to install dnsmasq package."
		return 1
	fi

	/sbin/chkconfig dnsmasq on	
	/etc/init.d/dnsmasq start
	#/sbin/service dnsmasq start

}

function init_server_etc_hosts {

	echo -n "Initializing /etc/hosts file with the internal server name..."
	if (( $# != 3 )); then
		echo "Failed to init etc hosts."
		echo "usage: init_server_etc_hosts <server name> <server internal ip>"
		exit 1
	fi

	local SERVER_NAME=$1
	local DOMAIN_NAME=$2
	local SERVER_IP=$3

	echo "127.0.0.1	localhost localhost.localdomain" > /etc/hosts
	echo "$SERVER_IP	$SERVER_NAME.$DOMAIN_NAME $SERVER_NAME" >> /etc/hosts

	hostname "$SERVER_NAME"
	if [ -f /etc/sysconfig/network ]; then
		sed -e "s|^HOSTNAME.*|HOSTNAME=$SERVER_NAME|" -i /etc/sysconfig/network
	fi
	if [ -f /etc/hostname ]; then
		echo "$SERVER_NAME" > /etc/hostname
	fi

	echo "OK"

}

function create_server_config {

	if (( $# != 3 )); then
		echo "Failed to create server config."
		echo "usage: create_server_key <server key name> <network> <subnet>"
		exit 1
	fi

	local SERVER_KEY_NAME=$1
	local VPN_NETWORK=$2
	local VPN_SUBNET=$3

	echo -n "Creating openvpn server config file..."

cat > "$OPENVPN_CONFIG_DIR/server.conf" <<-EOF_CAT
port 1194
proto tcp
dev tun
ca keys/ca.crt
cert keys/$SERVER_KEY_NAME.crt
key keys/$SERVER_KEY_NAME.key
dh keys/dh1024.pem
server $VPN_NETWORK $VPN_SUBNET

ifconfig-pool-persist ipp.txt
keepalive 10 120
comp-lzo
user nobody
group users
persist-key
persist-tun
status openvpn-status.log
verb 3
client-to-client

# accomplish the same this as a redirect-gatway def1
# except this works regardless of whether an existing default exists
push "route 0.0.0.0 128.0.0.0 vpn_gateway"
push "route 128.0.0.0 128.0.0.0 vpn_gateway"

client-config-dir ccd
EOF_CAT
[[ $? == 0 ]] || fail "Failed to create openvpn server config file."
echo "OK"

}

function configure_iptables {

# enable IP forwarding so clients can access the internet
echo -n "Enabling IP forwarding..."
sed -e "s|^net.ipv4.ip_forward.*|net.ipv4.ip_forward = 1|g" -i /etc/sysctl.conf
echo 1 > /proc/sys/net/ipv4/ip_forward
echo "OK"

local IPTABLES_CONFIG="/etc/sysconfig/iptables"
if [ -f /etc/debian_version ]; then
	IPTABLES_CONFIG="/etc/iptables.rules"
fi

echo -n "Creating openvpn server config file..."
cat > $IPTABLES_CONFIG <<-"EOF_CAT"
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:CLOUD_CONTROL - [0:0]
-A INPUT -j CLOUD_CONTROL
-A FORWARD -j CLOUD_CONTROL
-A CLOUD_CONTROL -i lo -j ACCEPT

#accept and forward traffic from tun0
-A CLOUD_CONTROL -i tun+ -j ACCEPT
-A FORWARD -i tun+ -j ACCEPT

-A CLOUD_CONTROL -p icmp --icmp-type any -j ACCEPT
-A CLOUD_CONTROL -m state --state ESTABLISHED,RELATED -j ACCEPT
-A CLOUD_CONTROL -m state --state NEW -m tcp -p tcp --dport 1194 -j ACCEPT
-A CLOUD_CONTROL -m state --state NEW -m udp -p udp --dport 1194 -j ACCEPT
-A CLOUD_CONTROL -m state --state NEW -m tcp -p tcp --dport 22 -j ACCEPT
-A CLOUD_CONTROL -j REJECT --reject-with icmp-host-prohibited
COMMIT

#Enable NAT to allow VPN clients to access internet
*nat
:PREROUTING ACCEPT
:POSTROUTING ACCEPT
:OUTPUT ACCEPT
-A POSTROUTING -o eth0 -j MASQUERADE

COMMIT
EOF_CAT

}
