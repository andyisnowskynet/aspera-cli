#!/bin/echo this is a ruby class:
#
# FASP transfer request
# Aspera 2016
# Laurent Martin
#
##############################################################################
require 'asperalm/log'
require 'socket'
require 'rbconfig'
require 'tempfile'
require 'timeout'
require "base64"
require "json"

module Asperalm

  ASPERA_SSH_BYPASS_DSA_KEY_VALUE="-----BEGIN DSA PRIVATE KEY-----
MIIBuwIBAAKBgQDkKQHD6m4yIxgjsey6Pny46acZXERsJHy54p/BqXIyYkVOAkEp
KgvT3qTTNmykWWw4ovOP1+Di1c/2FpYcllcTphkWcS8lA7j012mUEecXavXjPPG0
i3t5vtB8xLy33kQ3e9v9/Lwh0xcRfua0d5UfFwopBIAXvJAr3B6raps8+QIVALws
yeqsx3EolCaCVXJf+61ceJppAoGAPoPtEP4yzHG2XtcxCfXab4u9zE6wPz4ePJt0
UTn3fUvnQmJT7i0KVCRr3g2H2OZMWF12y0jUq8QBuZ2so3CHee7W1VmAdbN7Fxc+
cyV9nE6zURqAaPyt2bE+rgM1pP6LQUYxgD3xKdv1ZG+kDIDEf6U3onjcKbmA6ckx
T6GavoACgYEAobapDv5p2foH+cG5K07sIFD9r0RD7uKJnlqjYAXzFc8U76wXKgu6
WXup2ac0Co+RnZp7Hsa9G+E+iJ6poI9pOR08XTdPly4yDULNST4PwlfrbSFT9FVh
zkWfpOvAUc8fkQAhZqv/PE6VhFQ8w03Z8GpqXx7b3NvBR+EfIx368KoCFEyfl0vH
Ta7g6mGwIMXrdTQQ8fZs
-----END DSA PRIVATE KEY-----"

  # imlement this class to get transfer events
  class FileTransferListener
    def event(data)
      raise 'must be defined'
    end
  end

  # listener for FASP transfers (debug)
  class FaspListenerLogger < FileTransferListener
    def initialize
      @progress=nil
    end

    def event(data)
      Log.log.debug "#{data}"
      if data['Type'].eql?('NOTIFICATION') and data.has_key?('PreTransferBytes') then
        require 'ruby-progressbar'
        @progress=ProgressBar.create(:title => 'progress', :total => data['PreTransferBytes'].to_i)
      end
      if data['Type'].eql?('STATS') and !@progress.nil? then
        #@progress.progress=data['TransferBytes'].to_i
      end
      if data['Type'].eql?('DONE') and ! @progress.nil? then
        @progress.progress=@progress.total
        @progress=nil
      end
    end
  end

  # error raised if transfer fails
  class TransferError < StandardError
    attr_reader :err_code
    def initialize(err_code)
      @err_code = err_code
    end
  end

  # Manages FASP based transfers
  class FaspManager
    def initialize
      @mgt_sock=nil
      @ascp_pid=nil
      set_ascp_location
    end

    def set_listener(listener)
      @listener=listener
      self
    end

    def yes_to_true(value)
      case value
      when 'yes'; return true
      when 'no'; return false
      end
      raise "unsupported value: #{value}"
    end

    # extract transfer information from xml returned by faspex
    # only external users get token in link (see: <faspex>/app/views/delivery/_content.xml.builder)
    def fasp_uri_to_transferspec(fasplink)
      transfer_uri=URI.parse(fasplink)
      transfer_spec={}
      transfer_spec['remote_host']=transfer_uri.host
      transfer_spec['remote_user']=transfer_uri.user
      transfer_spec['ssh_port']=transfer_uri.port
      transfer_spec['paths']=[{"source"=>URI.decode_www_form_component(transfer_uri.path)}]

      URI::decode_www_form(transfer_uri.query).each do |i|
        name=i[0]
        value=i[1]
        case name
        when 'port'; transfer_spec['ssh_port']=value
        when 'cookie'; transfer_spec['cookie']=value
        when 'token'; transfer_spec['token']=value
        when 'policy'; transfer_spec['rate_policy']=value
        when 'httpport'; transfer_spec['http_fallback_port']=value
        when 'targetrate'; transfer_spec['target_rate_kbps']=value
        when 'minrate'; transfer_spec['min_rate_kbps']=value
        when 'port'; transfer_spec['fasp_port']=value
        when 'enc'; transfer_spec['cipher']=value
        when 'tags64'; transfer_spec['tags64']=value
        when 'bwcap'; transfer_spec['target_rate_cap_kbps']=value
        when 'createpath'; transfer_spec['create_dir']=yes_to_true(value)
        when 'fallback'; transfer_spec['http_fallback']=yes_to_true(value)
        when 'auth'; # TODO: why ignore ?
        when 'lockpolicy'; # TODO: why ignore ?
        when 'lockminrate'; # TODO: why ignore ?
        when 'v'; # TODO: why ignore ?
        else Log.log.error("non managed URI value: #{name} = #{value}".red)
        end
      end
      return transfer_spec
    end

    # start ascp
    # raises TransferError
    # uses ascp management port.
    def execute_ascp(command,arguments,env_vars)
      # open random local TCP port listening
      @mgt_sock = TCPServer.new('127.0.0.1', 0)
      port = @mgt_sock.addr[1]
      Log.log.debug "Port=#{port}"
      # add management port
      arguments.unshift '-M', port.to_s
      Log.log.info "execute #{env_vars.map{|k,v| "#{k}=\"#{v}\""}.join(' ')} \"#{command}\" \"#{arguments.join('" "')}\""
      begin
        @ascp_pid = Process.spawn(env_vars,[command,command],*arguments)
      rescue SystemCallError=> e
        raise TransferError.new(-1),e.to_s
      end
      # in parent, wait for connection, max 3 seconds
      Log.log.debug "before accept for pid (#{@ascp_pid})"
      client=nil
      begin
        Timeout.timeout( 3 ) do
          client = @mgt_sock.accept
        end
      rescue Timeout::Error => e
        Process.kill 'INT',@ascp_pid
      end
      Log.log.debug "after accept (#{client})"

      if client.nil? then
        # avoid zombie
        Process.wait @ascp_pid
        raise TransferError.new(-1),'timeout waiting mgt port connect'
      end

      # records for one message
      current=nil

      # this is the last full status
      lastStatus=nil

      # read management port
      loop do
        begin
          # check process still present, else receive Errno::ESRCH
          Process.getpgid( @ascp_pid )
        rescue RangeError => e
          break
        end
        # TODO: timeout here ?
        line = client.gets
        if line.nil? then
          break
        end
        line.chomp!
        Log.log.debug "line=[#{line}]"
        if  line.empty? then
          # end frame
          if !current.nil? then
            if !@listener.nil? then
              @listener.event current
            end
            if 'DONE'.eql?(current['Type']) or 'ERROR'.eql?(current['Type']) then
              lastStatus = current
            end
          else
            Log.log.error "unexpected empty line"
          end
        elsif 'FASPMGR 2'.eql? line then
          # begin frame
          current = Hash.new
        elsif m=line.match('^([^:]+): (.*)$') then
          current[m[1]] = m[2]
        else
          Log.log.error "error parsing[#{line}]"
        end
      end

      # wait for sub process completion
      Process.wait(@ascp_pid)

      if !lastStatus.nil? then
        if 'DONE'.eql?(lastStatus['Type']) then
          return
        end
        Log.log.error "last status is [#{lastStatus}]"
      end

      raise TransferError.new(lastStatus['Code'].to_i),lastStatus['Description']
    end

    # set members: @ascp_path and optionally @connect_private_key_path
    def set_ascp_location

      # ascp command and key file
      lConnectAscpCmd = nil
      lConnectAscpId  = nil

      # TODO: detect Connect Client on all platforms
      case RbConfig::CONFIG['host_os']
      when /mswin|msys|mingw|cygwin|bccwin|wince|emc/
        # also: ENV{TEMP}/.. , or %USERPROFILE%\AppData\Local\
        pluginLocation = ENV['LOCALAPPDATA'] + '/Programs/Aspera/Aspera Connect'
        lConnectAscpCmd = pluginLocation + '/bin/ascp';
        lConnectAscpId  = pluginLocation + '/etc/asperaweb_id_dsa.openssh';
      when /darwin|mac os/
        pluginLocation = Dir.home + '/Applications/Aspera Connect.app/Contents/Resources';
        lConnectAscpCmd = pluginLocation + '/ascp';
        lConnectAscpId  = pluginLocation + '/asperaweb_id_dsa.openssh';
      else     # unix family
        pluginLocation = Dir.home + '/.aspera/connect';
        lConnectAscpCmd = pluginLocation + '/bin/ascp';
        lConnectAscpId  = pluginLocation + '/etc/asperaweb_id_dsa.openssh';
      end
      Log.log.debug "cmd= #{lConnectAscpCmd}"
      Log.log.debug "key= #{lConnectAscpId}"
      if File.file?(lConnectAscpCmd) and File.file?(lConnectAscpId ) then
        Log.log.debug "Using plugin: [#{lConnectAscpId}]"
        @ascp_path = lConnectAscpCmd
        @connect_private_key_path = lConnectAscpId
        return
      end

      lESAscpCmd = '/usr/bin/ascp'
      Log.log.debug "Using system ascp if available"
      if ! File.executable(lESAscpCmd ) then
        Log.log.error "no such cmd: [#{lESAscpCmd}]"
        raise "cannot find ascp on system"
      end

      @ascp_path= lESAscpCmd
    end

    # copy and translate argument+value from transfer spec to env var for ascp
    def ts2env(used_names,transfer_spec,env_vars,ts_name,env_name)
      if transfer_spec.has_key?(ts_name)
        env_vars[env_name] = transfer_spec[ts_name]
        used_names.push(ts_name)
      end
    end

    # copy and translate argument+value from transfer spec to arguments for ascp
    def ts2args_value(used_names,transfer_spec,ascp_args,ts_name,arg_name,&transform)
      if transfer_spec.has_key?(ts_name)
        if !transfer_spec[ts_name].nil?
          value=transfer_spec[ts_name]
          value=transform.call(value) if transform
          ascp_args.push(arg_name,value)
        end
        used_names.push(ts_name)
      end
    end

    # translate boolean transfer spec argument to command line argument
    def ts_bool_param(used_names,transfer_spec,ascp_args,ts_name,&get_arg_list)
      if transfer_spec.has_key?(ts_name)
        ascp_args.push(*get_arg_list.call(transfer_spec[ts_name]))
        used_names.push(ts_name)
      end
    end

    # ignore transfer spec argument
    def ts_ignore_param(used_names,ts_name)
      used_names.push(ts_name)
    end

    # translate transfer spec to env vars and command line arguments to ascp
    def transfer_spec_to_args_and_env(transfer_spec)
      used_names=[]
      # parameters with env vars
      env_vars = Hash.new
      ts2env(used_names,transfer_spec,env_vars,'password','ASPERA_SCP_PASS')
      ts2env(used_names,transfer_spec,env_vars,'EX_ssh_key_value','ASPERA_SCP_KEY')
      ts2env(used_names,transfer_spec,env_vars,'token','ASPERA_SCP_TOKEN')
      ts2env(used_names,transfer_spec,env_vars,'cookie','ASPERA_SCP_COOKIE')
      ts2env(used_names,transfer_spec,env_vars,'EX_at_rest_password','ASPERA_SCP_FILEPASS')
      ts2env(used_names,transfer_spec,env_vars,'EX_proxy_password','ASPERA_PROXY_PASS')

      # base args
      ascp_args = Array.new

      if !transfer_spec.has_key?('password') and !transfer_spec.has_key?('EX_ssh_key_value') and !transfer_spec.has_key?('EX_ssh_key_path') then
        raise TransferError.new(-1),'required: ssh key (value or path) or password'
      end

      case transfer_spec['cipher']
      when nil; # nothing to put on command line, encryption by default
      when 'aes-128'; used_names.push('cipher') # nothing to put on command line, encryption by default
      when 'aes128'; used_names.push('cipher') # nothing to put on command line, encryption by default (from faspe link)
      else raise TransferError.new(-1),"unsupported cipher: #{transfer_spec['cipher']}"
      end

      case transfer_spec['direction']
      when nil; raise TransferError.new(-1),"direction is required"
      when 'receive'; ascp_args.push('--mode','recv'); used_names.push('direction')
      when 'send'; ascp_args.push('--mode','send'); used_names.push('direction')
      else raise TransferError.new(-1),"unsupported direction: #{transfer_spec['direction']}"
      end

      ts2args_value(used_names,transfer_spec,ascp_args,'remote_user','--user')
      ts2args_value(used_names,transfer_spec,ascp_args,'remote_host','--host')
      ts2args_value(used_names,transfer_spec,ascp_args,'EX_ssh_key_path','-i')
      ts2args_value(used_names,transfer_spec,ascp_args,'target_rate_kbps','-l') { |rate| rate.to_s }
      ts2args_value(used_names,transfer_spec,ascp_args,'min_rate_kbps','-m') { |rate| rate.to_s }
      ts2args_value(used_names,transfer_spec,ascp_args,'ssh_port','-P') { |port| port.to_s }
      ts2args_value(used_names,transfer_spec,ascp_args,'fasp_port','-O') { |port| port.to_s }
      ts2args_value(used_names,transfer_spec,ascp_args,'http_fallback','-y') { |enable| enable ? '1' : '0' }
      ts2args_value(used_names,transfer_spec,ascp_args,'http_fallback_port','-t') { |port| port.to_s }
      ts2args_value(used_names,transfer_spec,ascp_args,'rate_policy','--policy')
      ts2args_value(used_names,transfer_spec,ascp_args,'source_root','--source-prefix')

      ts_bool_param(used_names,transfer_spec,ascp_args,'create_dir') { |create_dir| create_dir ? ['-d'] : [] }

      ts_ignore_param(used_names,'target_rate_cap_kbps')
      ts_ignore_param(used_names,'rate_policy_allowed')
      ts_ignore_param(used_names,'fasp_url')
      ts_ignore_param(used_names,'sshfp') # ???
      ts_ignore_param(used_names,'lock_rate_policy')
      ts_ignore_param(used_names,'lock_min_rate')

      # optional tags (  additional option to generate: {:space=>' ',:object_nl=>' ',:space_before=>'+',:array_nl=>'1'}  )
      ts2args_value(used_names,transfer_spec,ascp_args,'tags','--tags64') { |tags| Base64.strict_encode64(JSON.generate(tags)) }
      ts2args_value(used_names,transfer_spec,ascp_args,'tags64','--tags64') # from faspe link
      #ascp_args.push('--tags64', Base64.strict_encode64(JSON.generate(transfer_spec['tags']))) if transfer_spec.has_key?('tags')

      # optional args
      ascp_args.push(*transfer_spec['EX_ascp_args']) if transfer_spec.has_key?('EX_ascp_args')

      # source list: TODO : check presence, and if pairs
      raise TransferError.new(-1),"missing source paths" if !transfer_spec.has_key?('paths')
      ascp_args.push(*transfer_spec['paths'].map { |i| i['source']})
      used_names.push('paths')

      # destination
      raise TransferError.new(-1),"missing destination" if !transfer_spec.has_key?('destination_root')
      ascp_args.push(transfer_spec['destination_root'])
      used_names.push('destination_root')

      # warn about non translated arguments
      transfer_spec.keys.each { |key|
        if !used_names.include?(key)
          Log.log.error("did not manage: #{key} = #{transfer_spec[key]}".red)
        end
      }

      return ascp_args,env_vars
    end

    # replaces do_transfer
    # transforms transper_spec into command line arguments and env var, then calls execute_ascp
    def transfer_with_spec(transfer_spec)
      # if not provided, use standard key
      if !transfer_spec.has_key?('EX_ssh_key_value') and
      !transfer_spec.has_key?('EX_ssh_key_path') and
      transfer_spec.has_key?('token')
        if !@connect_private_key_path.nil?
          transfer_spec['EX_ssh_key_path'] = @connect_private_key_path
        else
          transfer_spec['EX_ssh_key_value'] = ASPERA_SSH_BYPASS_DSA_KEY_VALUE
        end
      end

      execute_ascp(@ascp_path,*transfer_spec_to_args_and_env(transfer_spec))

      return nil
    end
  end # FaspManager
end # AsperaLm
