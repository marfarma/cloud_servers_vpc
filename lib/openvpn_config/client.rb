module OpenvpnConfig

require 'util/ssh'
require 'openvpn_config/bootstrap'

class Client

	attr_accessor :external_ip_addr
	@server=nil
	@ssh_as_user=""
	@ssh_identity_file="" #defaults to ~/.ssh/id_rsa
	@logger=nil
	@hostname=nil

	include OpenvpnConfig::Bootstrap

	def initialize(server, external_ip_addr, ssh_as_user="root", ssh_identity_file="#{ENV['HOME']}/.ssh/id_rsa")
		@server=server	
		@external_ip_addr=external_ip_addr
		@ssh_as_user=ssh_as_user
		@ssh_identity_file=ssh_identity_file
	end

	def logger=(logger)
		@logger=logger
	end

	# It is the job of the caller to track and ensure unique IP's get
	# used for the internal_vpn_ip and pptp_vpn_ip options.
	def configure_client_vpn(client_hostname, internal_vpn_ip, pptp_vpn_ip)
		@hostname=client_hostname

		# on the server we'll generate a new client cert
		tmp_cert=@server.add_vpn_client(client_hostname, internal_vpn_ip, pptp_vpn_ip)
		# scp the client cert to the client machine	
		retval=system("scp -i \"#{@ssh_identity_file}\" #{tmp_cert} #{@ssh_as_user}@#{@external_ip_addr}:/etc/openvpn/cert.tar.gz")
		File.delete(tmp_cert) if File.exists?(tmp_cert)

		if not retval then

			@logger.error("Failed to copy cert to client.")
			return false

		end

		script = <<-SCRIPT_EOF
			mkdir -p /etc/openvpn/
			cd /etc/openvpn/
			tar xzf /etc/openvpn/cert.tar.gz
			#{IO.read(File.join(File.dirname(__FILE__), "client_functions.bash"))}
			init_client_etc_hosts '#{client_hostname}' '#{@server.domain_name}' '#{internal_vpn_ip}'
			create_client_config #{@server.internal_ip_addr} #{@server.vpn_ipaddr} #{client_hostname} #{@server.domain_name}
		SCRIPT_EOF
		return Util::Ssh.run_cmd(@external_ip_addr, script, @ssh_as_user, @ssh_identity_file, @logger)

	end

	def start_openvpn

		script = "/sbin/chkconfig openvpn on\n/etc/init.d/openvpn start\n"
		if Util::Ssh.run_cmd(@external_ip_addr, script, @ssh_as_user, @ssh_identity_file, @logger) then
			if_down_count=0
			1.upto(5) do
				break if @server.if_down_eth0_client(@hostname)
				if_down_count+=1
			end
			return true if if_down_count < 5
		end
		return false

	end

end

end
