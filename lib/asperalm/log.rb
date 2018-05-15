require 'asperalm/colors'
require 'logger'
require 'pp'
require 'singleton'

# Singleton object for logging
module Asperalm
  # Singleton object for logging, should be Module ?
  class Log

    public
    include Singleton

    attr_reader :logger
    attr_reader :logger_type
    # levels are :debug,:info,:warn,:error,fatal,:unknown
    def self.levels; Logger::Severity.constants.map{|c| c.downcase.to_sym};end

    def self.logtypes; [:stderr,:stdout,:syslog];end

    # get the logger object of singleton
    def self.log; self.instance.logger; end

    # dump object in debug mode
    def self.dump(name,object)
      self.log.debug("#{name}=\n#{PP.pp(object,'')}")
    end

    # set log level of underlying logger given symbol level
    def level=(new_level)
      @logger.level=Logger::Severity.const_get(new_level.to_sym.upcase)
    end

    # get symbol of debug level of underlying logger
    def level
      Logger::Severity.constants.each do |name|
        return name.downcase.to_sym if @logger.level.eql?(Logger::Severity.const_get(name))
      end
      raise "error"
    end

    # change underlying logger, but keep log level
    def logger_type=(new_logtype)
      current_severity_integer=@logger.nil? ? Logger::Severity::WARN : @logger.level
      case new_logtype
      when :stderr
        @logger = Logger.new(STDERR)
      when :stdout
        @logger = Logger.new(STDOUT)
      when :syslog
        require 'syslog/logger'
        @logger = Syslog::Logger.new('aslmcli')
      else
        raise "unknown log type: #{new_logtype.class} #{new_logtype}"
      end
      @logger.level=current_severity_integer
      @logger_type=new_logtype
    end
    
    private

    def initialize
      @logger=nil
      # set @logger and @logger_type
      self.logger_type=:stderr
    end

  end
end
