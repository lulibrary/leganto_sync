require 'dotenv/load'

require 'minitest/autorun'
require 'minitest/reporters'

require 'lusi_api/core/api'


Minitest::Reporters.use!


class Test < Minitest::Test

  @@lusi_api = nil
  @@lusi_api_password = ENV['LUSI_API_PASSWORD']
  @@lusi_api_user = ENV['LUSI_API_USER']
  @@lusi_lookup = nil
  @@logger = Logger.new(STDOUT)
  @@logger.level = Logger::DEBUG
  @@mutex_lusi_api = Mutex.new
  @@mutex_lusi_lookup = Mutex.new

  def setup

  end

  def teardown

  end

  protected

  def get_lusi_api
    @@mutex_lusi_api.synchronize do
      return @@lusi_api if @@lusi_api
      @@lusi_api = LUSI::API::Core::API.new(api_user: @@lusi_api_user, api_password: @@lusi_api_password, logger: @@logger)
    end
    @@lusi_api
  end

  def get_lusi_lookup
    lusi_api = get_lusi_api
    @@mutex_lusi_lookup.synchronize do
      return @@lusi_lookup if @@lusi_lookup
      @@lusi_lookup = LUSI::API::Core::Lookup::LookupService.new(lusi_api)
      @@lusi_lookup.load
    end
    @@lusi_lookup
  end

end