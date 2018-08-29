require 'asperalm/rest'

module Asperalm
  module Cli
    # base class for applications supporting basic authentication
    class BasicAuthPlugin < Plugin
      # returns a Rest object with basic auth
      def basic_auth_api(subpath=nil)
        api_url=Main.instance.options.get_option(:url,:mandatory)
        api_url=api_url+'/'+subpath unless subpath.nil?
        return Rest.new({
          :base_url       => api_url,
          :auth_type      => :basic,
          :basic_username => Main.instance.options.get_option(:username,:mandatory),
          :basic_password => Main.instance.options.get_option(:password,:mandatory)})
      end

      def declare_options
        Main.instance.options.add_opt_simple(:url,"URL of application, e.g. https://org.asperafiles.com")
        Main.instance.options.add_opt_simple(:username,"username to log in")
        Main.instance.options.add_opt_simple(:password,"user's password")
      end
    end # BasicAuthPlugin
  end # Cli
end # Asperalm
