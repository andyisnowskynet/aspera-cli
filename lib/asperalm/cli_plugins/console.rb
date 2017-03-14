require 'optparse'
require 'pp'
require 'asperalm/rest'
require 'asperalm/colors'
require 'asperalm/opt_parser'

module Asperalm
  module CliPlugins
    class Console
      def opt_names; [:url,:username,:password]; end

      attr_accessor :logger
      attr_accessor :faspmanager

      def initialize(logger)
        @logger=logger
      end

      def go(argv,defaults)
        begin
          @opt_parser = OptParser.new(self)
          @opt_parser.set_defaults(defaults)
          @opt_parser.banner = "NAME\n\t#{$0} -- a command line tool for Aspera Applications\n\n"
          @opt_parser.separator "SYNOPSIS"
          @opt_parser.separator "\t#{$0} ... node [OPTIONS] COMMAND [ARGS]..."
          @opt_parser.separator ""
          @opt_parser.separator "OPTIONS"
          @opt_parser.add_opt_simple(:url,"-wURI", "--url=URI","URL of application, e.g. http://org.asperafiles.com")
          @opt_parser.add_opt_simple(:username,"-uSTRING", "--username=STRING","username to log in")
          @opt_parser.add_opt_simple(:password,"-pSTRING", "--password=STRING","password")
          @opt_parser.on_tail("-h", "--help", "Show this message") { @opt_parser.exit_with_usage }
          @opt_parser.parse_ex!(argv)

          results=''

          command=OptParser.get_next_arg_from_list(argv,'command',[ :put, :get, :transfers, :info ])

          api_node=Rest.new(@logger,@opt_parser.get_option_mandatory(:url),{:basic_auth=>{:user=>@opt_parser.get_option_mandatory(:username), :password=>@opt_parser.get_option_mandatory(:password)}})

          case command
          when :put
            filelist = argv
            @logger.debug("file list=#{filelist}")
            if filelist.length < 2 then
              raise OptionParser::InvalidArgument,"Missing source(s) and destination"
            end

            destination=filelist.pop

            send_result=api_node.call({:operation=>'POST',:subpath=>'files/upload_setup',:json_params=>{ :transfer_requests => [ { :transfer_request => { :paths => [ { :destination => destination } ] } } ] }})
            if send_result[:data]['transfer_specs'][0].has_key?('error')
              raise send_result[:data]['transfer_specs'][0]['error']['user_message']
            end
            send_result[:data]['transfer_specs'].each{ |s|
              session=s['transfer_spec']
              results=@faspmanager.do_transfer(
              :mode    => :send,
              :dest    => session['destination_root'],
              :user    => session['remote_user'],
              :host    => session['remote_host'],
              :token   => session['token'],
              #:cookie  => session['cookie'],
              #:tags    => session['tags'],
              :srcList => filelist,
              :rawArgs => [ '-P', '33001', '-d', '-q', '--ignore-host-key', '-k', '2', '--save-before-overwrite','--partial-file-suffix=.partial' ],
              :retries => 10,
              :use_aspera_key => true)
            }
          when :get
            filelist = argv
            @logger.debug("file list=#{filelist}")
            if filelist.length < 2 then
              raise OptionParser::InvalidArgument,"Missing source(s) and destination"
            end

            destination=filelist.pop

            send_result=api_node.call({:operation=>'POST',:subpath=>'files/download_setup',:json_params=>{ :transfer_requests => [ { :transfer_request => { :paths => filelist.map {|i| {:source=>i}; } } } ] }})
            if send_result[:data]['transfer_specs'][0].has_key?('error')
              raise send_result[:data]['transfer_specs'][0]['error']['user_message']
            end

            send_result[:data]['transfer_specs'].each{ |s|
              session=s['transfer_spec']
              srcList = session['paths'].map { |i| i['source']}
              results=@faspmanager.do_transfer(
              :mode    => :recv,
              :dest    => destination,
              :user    => session['remote_user'],
              :host    => session['remote_host'],
              :token   => session['token'],
              :cookie  => session['cookie'],
              :tags    => session['tags'],
              :srcList => srcList,
              :rawArgs => [ '-P', '33001', '-d', '-q', '--ignore-host-key', '-k', '2', '--save-before-overwrite','--partial-file-suffix=.partial' ],
              :retries => 10,
              :use_aspera_key => true)
            }
          when :transfers
            command=OptParser.get_next_arg_from_list(argv,'command',[ :list ])
            # ,:url_params=>{:active_only=>true}
            resp=api_node.call({:operation=>'GET',:subpath=>'ops/transfers',:headers=>{'Accept'=>'application/json'}})
            results=resp[:data]
          when :info
            resp=api_node.call({:operation=>'GET',:subpath=>'info',:headers=>{'Accept'=>'application/json'}})
            results=resp[:data]
          end

          if ! results.nil? then
            puts PP.pp(results,'')
            #puts results
          end

        rescue OptionParser::InvalidArgument => e
          STDERR.puts "ERROR:".bg_red().gray()+" #{e}\n\n"
          @opt_parser.exit_with_usage
        end
        return
      end
    end
  end # Cli
end # Asperalm
