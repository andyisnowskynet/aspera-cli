# frozen_string_literal: true

require 'aspera/fasp/transfer_spec'
require 'aspera/rest'
require 'aspera/oauth'
require 'aspera/log'
require 'aspera/environment'
require 'zlib'
require 'base64'

module Aspera
  # Provides additional functions using node API with gen4 extensions (access keys)
  class Node < Rest
    # permissions
    ACCESS_LEVELS = %w[delete list mkdir preview read rename write].freeze
    # prefix for ruby code for filter
    MATCH_EXEC_PREFIX = 'exec:'
    X_ASPERA_ACCESSKEY = 'X-Aspera-AccessKey'

    # register node special token decoder
    Oauth.register_decoder(lambda{|token|JSON.parse(Zlib::Inflate.inflate(Base64.decode64(token)).partition('==SIGNATURE==').first)})

    # class instance variable, access with accessors on class
    @use_standard_ports = true

    class << self
      attr_accessor :use_standard_ports
      def set_ak_basic_token(ts, ak, secret)
        Log.log.warn("Expected transfer user: #{Fasp::TransferSpec::ACCESS_KEY_TRANSFER_USER}, "\
          "but have #{ts['remote_user']}") unless ts['remote_user'].eql?(Fasp::TransferSpec::ACCESS_KEY_TRANSFER_USER)
        ts['token'] = Rest.basic_creds(ak, secret)
      end

      # for access keys: provide expression to match entry in folder
      # if no prefix: regex
      # if prefix: ruby code
      # if filder is nil, then always match
      def file_matcher(match_expression)
        match_expression ||= "#{MATCH_EXEC_PREFIX}true"
        if match_expression.start_with?(MATCH_EXEC_PREFIX)
          return Environment.secure_eval("lambda{|f|#{match_expression[MATCH_EXEC_PREFIX.length..-1]}}")
        end
        return lambda{|f|f['name'].match(/#{match_expression}/)}
      end
    end

    REQUIRED_APP_INFO_FIELDS=%i[node_info app api plugin].freeze
    REQUIRED_APP_API_METHODS=%i[node_id_to_api add_ts_tags].freeze
    private_constant :REQUIRED_APP_INFO_FIELDS, :REQUIRED_APP_API_METHODS

    attr_reader :app_info

    # @param params [Hash] Rest parameters
    # @param app_info [Hash,NilClass] special processing for AoC
    def initialize(params:, app_info: nil)
      super(params)
      @app_info=app_info
      if !@app_info.nil?
        REQUIRED_APP_INFO_FIELDS.each do |field|
          raise "INTERNAL ERROR: app_info lacks field #{field}" unless @app_info.has_key?(field)
        end
        REQUIRED_APP_API_METHODS.each do |method|
          raise "INTERNAL ERROR: #{@app_info[:api].class} lacks method #{method}" unless @app_info[:api].respond_to?(method)
        end
      end
    end

    # @returns [Aspera::Node] a Node or nil
    def node_id_to_node(node_id)
      return self if !@app_info.nil? && @app_info[:node_info]['id'].eql?(node_id)
      return @app_info[:api].node_id_to_api(node_id) unless @app_info.nil?
      Log.log.warn("cannot resolve link with node id #{node_id}")
      return nil
    end

    # recursively browse in a folder (with non-recursive method)
    # subfolders a processed if the processing method returns true
    # @param state [Object] state object sent to processing method
    # @param method [Symbol] processing method name
    # @param top_file_id [String] file id to start at (default = access key root file id)
    # @param top_file_path [String] path of top folder (default = /)
    def process_folder_tree(state:, method:, top_file_id:, top_file_path: '/')
      raise 'INTERNAL ERROR: top_file_path not set' if top_file_path.nil?
      raise "INTERNAL ERROR: Missing method #{method}" unless respond_to?(method)
      folders_to_explore = [{id: top_file_id, relpath: top_file_path}]
      Log.dump(:folders_to_explore, folders_to_explore)
      while !folders_to_explore.empty?
        current_item = folders_to_explore.shift
        Log.log.debug("searching #{current_item[:relpath]}".bg_green)
        # get folder content
        folder_contents =
          begin
            read("files/#{current_item[:id]}/files")[:data]
          rescue StandardError => e
            Log.log.warn("#{current_item[:relpath]}: #{e.class} #{e.message}")
            []
          end
        Log.dump(:folder_contents, folder_contents)
        folder_contents.each do |entry|
          relative_path = File.join(current_item[:relpath], entry['name'])
          Log.log.debug("looking #{relative_path}".bg_green)
          # continue only if method returns true
          next unless send(method, entry, relative_path, state)
          # entry type is file, folder or link
          case entry['type']
          when 'folder'
            folders_to_explore.push({id: entry['id'], relpath: relative_path})
          when 'link'
            node_id_to_node(entry['target_node_id'])&.process_folder_tree(
              state:         state,
              method:        method,
              top_file_id:   entry['target_id'],
              top_file_path: relative_path)
          end
        end
      end
    end # process_folder_tree

    # processing method to resolve a file path to id
    # @returns true if processing need to continue
    def process_resolve_node_path(entry, path, state)
      # stop digging here if not in right path
      return false unless entry['name'].eql?(state[:path].first)
      # ok it matches, so we remove the match
      state[:path].shift
      case entry['type']
      when 'file'
        # file must be terminal
        raise "#{entry['name']} is a file, expecting folder to find: #{state[:path]}" unless state[:path].empty?
        # it's terminal, we found it
        state[:result] = {api: self, file_id: entry['id']}
        return false
      when 'folder'
        if state[:path].empty?
          # we found it
          state[:result] = {api: self, file_id: entry['id']}
          return false
        end
      when 'link'
        if state[:path].empty?
          # we found it
          other_node = node_id_to_node(entry['target_node_id'])
          raise 'cannot resolve link' if other_node.nil?
          state[:result] = {api: other_node, file_id: entry['target_id']}
          return false
        end
      else
        Log.log.warn("Unknown element type: #{entry['type']}")
      end
      # continue to dig folder
      return true
    end

    # Navigate the path from given file id
    # @param id initial file id
    # @param path file path
    # @return {.api,.file_id}
    def resolve_api_fid(top_file_id, path)
      path_elements = path.split(AoC::PATH_SEPARATOR).reject(&:empty?)
      return {api: self, file_id: top_file_id} if path_elements.empty?
      resolve_state = {path: path_elements, result: nil}
      process_folder_tree(state: resolve_state, method: :process_resolve_node_path, top_file_id: top_file_id)
      raise "entry not found: #{resolve_state[:path]}" if resolve_state[:result].nil?
      return resolve_state[:result]
    end

    # add entry to list if test block is success
    def process_find_files(entry, path, state)
      begin
        # add to result if match filter
        state[:found].push(entry.merge({'path' => path})) if state[:test_block].call(entry)
        # process link
        if entry[:type].eql?('link')
          other_node = node_id_to_node(entry['target_node_id'])
          other_node.process_folder_tree(state: state, method: process_find_files, top_file_id: entry['target_id'], top_file_path: path)
        end
      rescue StandardError => e
        Log.log.error("#{path}: #{e.message}")
      end
      # process all folders
      return true
    end

    def find_files(top_file_id, test_block)
      Log.log.debug("find_files: fileid=#{top_file_id}")
      find_state = {found: [], test_block: test_block}
      process_folder_tree(state: find_state, method: :process_find_files, top_file_id: top_file_id)
      return find_state[:found]
    end

    # Create transfer spec for gen4
    def transfer_spec_gen4(file_id, direction, ts_merge=nil)
      ak_name = nil
      ak_token = nil
      case params[:auth][:type]
      when :basic
        ak_name=params[:auth][:username]
      when :oauth2
        ak_name=params[:headers][X_ASPERA_ACCESSKEY]
        token_generation_lambda = lambda{|do_refresh|oauth_token(force_refresh: do_refresh)}
        ak_token=token_generation_lambda.call(false) # first time, use cache
        @app_info[:plugin].transfer.token_regenerator = token_generation_lambda unless @app_info.nil?
      else raise "Unsupported auth method for node gen4: #{params[:auth][:type]}"
      end
      transfer_spec = {
        'direction' => direction,
        'token'     => ak_token,
        'tags'      => {
          'aspera' => {
            'node' => {
              'access_key' => ak_name,
              'file_id'    => file_id
            } # node
          } # aspera
        } # tags
      }
      transfer_spec.deep_merge!(ts_merge) unless ts_merge.nil?
      # add application specific tags (AoC)
      the_app=app_info
      the_app[:api].add_ts_tags(transfer_spec: transfer_spec, app_info: the_app) unless the_app.nil?
      # add basic token
      if transfer_spec['token'].nil?
        Aspera::Node.set_ak_basic_token(transfer_spec, params[:auth][:username], params[:auth][:password])
      end
      # add remote host info
      if self.class.use_standard_ports
        # get default TCP/UDP ports and transfer user
        transfer_spec.merge!(Fasp::TransferSpec::AK_TSPEC_BASE)
        # by default: same address as node API
        transfer_spec['remote_host'] = URI.parse(params[:base_url]).host
        if !@app_info.nil? && !@app_info[:node_info]['transfer_url'].nil? && !@app_info[:node_info]['transfer_url'].empty?
          transfer_spec['remote_host'] = @app_info[:node_info]['transfer_url']
        end
      else
        # retrieve values from API
        std_t_spec = create(
          'files/download_setup',
          {transfer_requests: [{ transfer_request: {paths: [{'source' => '/'}] } }] }
        )[:data]['transfer_specs'].first['transfer_spec']
        # copy some parts
        %w[remote_host remote_user ssh_port fasp_port wss_enabled wss_port].each {|i| transfer_spec[i] = std_t_spec[i] if std_t_spec.has_key?(i)}
      end
      return transfer_spec
    end
  end
end
