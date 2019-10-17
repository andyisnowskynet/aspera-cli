require 'asperalm/fasp/manager'
require 'asperalm/rest'
require 'asperalm/open_application'
require 'securerandom'
require 'singleton'
require 'tty-spinner'

module Asperalm
  module Fasp
    class Connect < Manager
      include Singleton
      private
      # mode=node : activate, set to the REST api object for the node API
      def initialize
        super
        @connect_app_id=SecureRandom.uuid
        # TODO: start here and create monitor
      end
      MAX_CONNECT_START_RETRY=3
      private_constant :MAX_CONNECT_START_RETRY
      public

      def start_transfer(transfer_spec,options=nil)
        raise "Using connect requires a graphical environment" if !OpenApplication.default_gui_mode.eql?(:graphical)
        trynumber=0
        begin
          uri_file=Installation.instance.connect_uri_file
          Log.log.debug("reading connect port file: #{uri_file}")
          connect_url=File.open(uri_file){|f|f.gets}.strip
          Log.log.debug("found: #{connect_url}")
          @connect_api=Rest.new({:base_url => "#{connect_url}/v5/connect"}) # could use v6 also now
          cinfo=@connect_api.read('info/version')[:data]
        rescue => e # Errno::ECONNREFUSED
          raise StandardError,"Unable to start connect after #{trynumber} try" if trynumber >= MAX_CONNECT_START_RETRY
          Log.log.warn("connect is not started. Retry ##{trynumber}, err=#{e}")
          trynumber+=1
          if !OpenApplication.uri_graphical('fasp://initialize')
            OpenApplication.uri_graphical('https://downloads.asperasoft.com/connect2/')
            raise StandardError,"Connect is not installed"
          end
          sleep 2
          retry
        end
        if transfer_spec["direction"] == "send"
          Log.log.warn("Connect requires upload selection using GUI, ignoring #{transfer_spec['paths']}".red)
          transfer_spec.delete('paths')
          resdata=@connect_api.create('windows/select-open-file-dialog/',{"title"=>"Select Files","suggestedName"=>"","allowMultipleSelection"=>true,"allowedFileTypes"=>"","aspera_connect_settings"=>{"app_id"=>@connect_app_id}})[:data]
          transfer_spec['paths']=resdata['dataTransfer']['files'].map { |i| {'source'=>i['name']}}
        end
        @request_id=SecureRandom.uuid
        #transfer_spec['authentication']="token" if transfer_spec.has_key?('token')
        connect_transfer_args={
          'transfer_specs'=>[{
          'transfer_spec'=>transfer_spec,
          'aspera_connect_settings'=>{
          'allow_dialogs'=>true,
          'app_id'=>@connect_app_id,
          'request_id'=>@request_id
          }}]}
        # asynchronous anyway
        @connect_api.create('transfers/start',connect_transfer_args)
      end

      def wait_for_transfers_completion
        connect_activity_args={'aspera_connect_settings'=>{'app_id'=>@connect_app_id}}
        started=false
        spinner=nil
        loop do
          result=@connect_api.create('transfers/activity',connect_activity_args)[:data]
          if result['transfers']
            trdata=result['transfers'].select{|i| i['aspera_connect_settings'] and i['aspera_connect_settings']['request_id'].eql?(@request_id)}.first
            raise "problem with connect, please kill it" unless trdata
            # TODO: get session id
            case trdata['status']
            when 'completed'
              notify_listeners("emulated",{'Type'=>'DONE'})
              break
            when 'initiating'
              if spinner.nil?
                spinner = TTY::Spinner.new("[:spinner] :title", format: :classic)
                spinner.start
              end
              spinner.update(title: trdata['status'])
              spinner.spin
            when 'running'
              #puts "running: sessions:#{trdata["sessions"].length}, #{trdata["sessions"].map{|i| i['bytes_transferred']}.join(',')}"
              if !started and trdata["bytes_expected"] != 0
                notify_listeners("emulated",{'Type'=>'NOTIFICATION','PreTransferBytes'=>trdata["bytes_expected"]})
                started=true
              else
                notify_listeners("emulated",{'Type'=>'STATS','Bytescont'=>trdata["bytes_written"]})
              end
            else
              raise Fasp::Error.new("#{trdata['status']}: #{trdata['error_desc']}")
            end
          end
          sleep 1
        end
        return [] #TODO
      end # wait
    end # Connect
  end
end
