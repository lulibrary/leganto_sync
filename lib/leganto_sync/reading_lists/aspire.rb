require 'base64'
require 'cgi'
require 'csv'
require 'json'

require 'loofah'
require 'net-ldap'
require 'rest-client'

require 'lusi_api/core/util'


module LegantoSync
  module ReadingLists
    module Aspire


      # Common utility methods
      module Util

        # Returns the ID of an object from its URI
        # @return [String] the object ID
        def id_from_uri(uri)
          # The ID should be the last component of the URI path, minus any format suffix (.html, .json etc.)
          result = uri.split('/')[-1]
          result = result.split('.')[0] if result
          result
        end

      end


      # Wrapper for the Talis Aspire API
      class API

        # @!attribute [rw] api_root
        #   @return [String] the base URL of the Aspire JSON APIs
        attr_accessor :api_root

        # @!attribute [rw] api_root_auth
        #   @return [String] the base URL of the Aspire Persona authentication API
        attr_accessor :api_root_auth

        # @!attribute [rw] api_version
        #   @return [Integer] the version of the Aspire JSON APIs
        attr_accessor :api_version

        # @!attribute [rw] logger
        #   @return [Logger] a logger for activity logging
        attr_accessor :logger

        # @!attribute [rw] rate_limit
        #   @return [Integer] the API call rate limit value from the most recent API call
        attr_accessor :rate_limit

        # @!attribute [rw] rate_remaining
        #   @return [Integer] the API calls remaining within the rate limit period from the most recent API call
        attr_accessor :rate_remaining

        # @!attribute [rw] rate_reset
        #   @return [Integer] the reset time of the rate limit (seconds since the Epoch) from the most recent API call
        attr_accessor :rate_reset

        # @!attribute [rw] tenancy_code
        #   @return [String] the Aspire short tenancy code
        attr_accessor :tenancy_code

        # @!attribute [rw] tenancy_root
        #   @return [String] the base canonical URL of the tenancy
        attr_accessor :tenancy_root

        # @!attribute [rw] timeout
        #   @return [Integer] the timeout period in seconds for API calls
        attr_accessor :timeout

        # Initialises a new API instance
        # @param api_client_id [String] the API client ID
        # @param api_secret [String] the API secret associated with the client ID
        # @param tenancy_code [String] the Aspire short tenancy code
        # @param api_root [String] the base URL of the Aspire JSON APIs
        # @param api_root_auth [String] the base URL of the Aspire Persona authentication API
        # @param api_version [Integer] the version of the Aspire JSON APIs
        # @param logger [Logger] a logger for activity logging
        # @param tenancy_root [String] the base canonical URL of the tenancy
        # @param timeout [Integer] the timeout period in seconds for API calls
        # @return [void]
        def initialize(api_client_id = nil, api_secret = nil, tenancy_code = nil, api_root: nil, api_root_auth: nil,
                       api_version: nil, logger: nil, tenancy_root: nil, timeout: nil)

          self.api_root = api_root || 'https://rl.talis.com'
          self.api_root_auth = api_root_auth || 'https://users.talis.com/1/oauth/tokens'
          self.api_version = api_version || 2
          self.logger = logger
          self.rate_limit = nil
          self.rate_remaining = nil
          self.rate_reset = nil
          self.tenancy_code = tenancy_code
          self.tenancy_root = tenancy_root
          self.timeout = timeout.to_i

          @api_client_id = api_client_id
          @api_secret = api_secret
          @api_token = nil

          RestClient.log = self.logger if self.logger

        end

        # Calls an Aspire API method and returns the parsed JSON response
        # Any undocumented keyword parameters are passed as query string parameters to the API call.
        # @param path [String] the path of the API call
        # @param auth [Boolean] add bearer token to headers if true
        # @param expand_path [Boolean] add the API root, version etc. to the path if true
        # @param headers [Hash<String, String>] optional HTTP headers for the API call
        # @param options [Hash<String, Object>] options for the REST client
        # @param payload [String, nil] the data to post to the API call
        # @return [Hash] the parsed JSON content from the API response
        # @yield [response, data] Passes the REST client response and parsed JSON hash to the block
        # @yieldparam [RestClient::Response] the REST client response
        # @yieldparam [Hash] the parsed JSON data from the response
        def call(path, headers: nil, options: nil, payload: nil, auth: true, expand_path: true, **params)

          # Set the REST client headers
          rest_headers = {}.merge(headers || {})
          rest_headers[:params] = params if params && !params.empty?

          # Set the REST client options
          rest_options = {
              headers: rest_headers,
              url: expand_path ? url(path) : path,
          }
          rest_options[:payload] = payload if payload
          rest_options[:timeout] = self.timeout > 0 ? self.timeout : nil
          rest_options.merge(options) if options
          rest_options[:method] ||= payload ? :post : :get

          data = nil
          refresh_token = false
          response = nil

          if auth
            loop do
              rest_headers['Authorization'] = "Bearer #{api_token(refresh_token)}"
              response, data = call_api(**rest_options)
              if response && response.code == 401 && !refresh_token
                # The API token may have expired, try one more time with a new token
                refresh_token = true
              else
                break
              end
            end
          else
            response, data = call_api(**rest_options)
          end

          yield(response, data) if block_given?

          data

        end

        # Returns parsed JSON data for a URI using the Aspire linked data API
        # @param url [String] the partial (minus the tenancy root) or complete tenancy URL of the resource
        # @param expand_path [Boolean] if true, add the tenancy root URL to url, otherwise assume url is a full URL
        # @return [Hash] the parsed JSON content from the API response
        # @yield [response, data] Passes the REST client response and parsed JSON hash to the block
        # @yieldparam [RestClient::Response] the REST client response
        # @yieldparam [Hash] the parsed JSON data from the response
        def get_json(url, expand_path: true, &block)
          url = tenancy_url(url) if expand_path
          url = "#{url}.json" unless url.end_with?('.json')
          call(url, auth: false, expand_path: false, &block)
        end

        # Returns a full Aspire tenancy URL from a partial resource path
        # @param path [String] the partial resource path
        # @return [String] the full tenancy URL
        def tenancy_url(path)
          "#{self.tenancy_root}/#{path}"
        end

        # Returns a full Aspire JSON API URL from a partial endpoint path
        # @param path [String] the partial endpoint path
        # @return [String] the full JSON API URL
        def url(path)
          "#{self.api_root}/#{self.api_version}/#{self.tenancy_code}/#{path}"
        end


        protected

        # Returns an Aspire OAuth API token. New tokens are retrieved from the Aspire Persona API and stored for
        # subsequent API calls.
        # @param refresh [Boolean] if true, retrieves a new token, otherwise returns the cached token if available
        def api_token(refresh = false)

          # Return the cached token if available unless forcing a refresh
          return @api_token unless @api_token.nil? || refresh

          # Set the Basic authentication token
          authorization = Base64.strict_encode64("#{@api_client_id}:#{@api_secret}")

          # Set the REST client headers
          rest_headers = {
              'Authorization': "basic #{authorization}",
              'Content-Type': 'application/x-www-form-urlencoded'
          }

          # Set the REST client options
          rest_options = {
              headers: rest_headers,
              payload: { grant_type: 'client_credentials' },
              url: self.api_root_auth
          }
          rest_options[:timeout] = self.timeout > 0 ? self.timeout : nil
          rest_options[:method] = :post

          # Make the API call
          begin
            response, data = call_api(**rest_options)
            @api_token = data['access_token']
          rescue Exception => e
            # Set the token to nil on failure
            @api_token = nil
            raise
          end

          @api_token

        end

        # Calls an Aspire API endpoint and processes the response
        # Keyword parameters are passed directly to the REST client
        # @return [(RestClient::Response, Hash)] the REST client response and parsed JSON data from the response
        def call_api(**rest_options)
          json = nil
          response = nil
          begin
            response = RestClient::Request.execute(**rest_options)
            json = JSON.parse(response.to_s) if response && !response.empty?
            headers = response.headers
            self.rate_limit = headers[:x_ratelimit_limit].to_i if headers.include?(:x_ratelimit_limit)
            self.rate_remaining = headers[:x_ratelimit_remaining].to_i if headers.include?(:x_ratelimit_remaining)
            self.rate_reset = Time.at(headers[:x_ratelimit_reset].to_i) if headers.include?(:x_ratelimit_reset)
          rescue RestClient::Exceptions::Timeout => e
            raise
          rescue RestClient::ExceptionWithResponse => e
            response = e.response
            #json = JSON.parse(response.to_s) if response && !response.empty?
            json = nil
          rescue => e
            raise
          end
          return response, json
        end

      end


      class APIObject

        # Aspire properties containing HTML markup will have the markup stripped if STRIP_HTML = true
        STRIP_HTML = true

        include Util

        # @!attribute [rw] factory
        #   @return [LegantoSync::ReadingLists::Aspire::Factory] the factory for creating APIObject instances
        attr_accessor :factory

        # @!attribute [rw] uri
        #   @return [String] the URI of the object
        attr_accessor :uri

        # Initialises a new APIObject instance
        # @param uri [String] the URI of the object
        # @param factory [LegantoSync::ReadingLists::Aspire::Factory] the factory for creating APIObject instances
        # @return [void]
        def initialize(uri, factory)
          self.factory = factory
          self.uri = uri
        end

        # Returns a DateTime instance for a timestamp property
        # @param property [String] the property name
        # @param data [Hash] the data hash containing the property (defaults to self.ld)
        # @param uri [String] the URI index of the data hash containing the property (defaults to self.uri)
        # @param single [Boolean] if true, return a single value, otherwise return an array of values
        # @return [DateTime, Array<DateTime>] the property value(s)
        def get_date(property, data, uri = nil, single: true)
          get_property(property, data, uri, single: single) { |value, type| DateTime.parse(value) }
        end

        # Returns the value of a property
        # @param property [String] the property name
        # @param data [Hash] the data hash containing the property (defaults to self.data)
        # @param uri [String] the URI index of self.data containing the property (ignored if data is passed)
        # @param is_url [Boolean] if true, the property value is a URL
        # @param single [Boolean] if true, return a single value, otherwise return an array of values
        # @return [Object, Array<Object>] the property value(s)
        # @yield [value, type] passes the value and type to the block
        # @yieldparam value [Object] the property value
        # @yieldparam type [String] the type of the property value
        # @yieldreturn [Object] the transformed property value
        def get_property(property, data, uri = nil, is_url: false, single: true, &block)
          values = data ? data[property] : nil
          if values.is_a?(Array)
            values = values.map { |value| get_property_value(value, is_url: is_url, &block) }
            single ? values[0] : values
          else
            value = get_property_value(values, is_url: is_url, &block)
            single ? value : [value]
          end
        end

        # Returns a string representation of the APIObject instance (the URI)
        # @return [String] the string representation of the APIObject instance
        def to_s
          self.uri.to_s
        end

        protected

        # Retrieves and transforms the property value
        # @param value [String] the property value from the Aspire API
        # @param is_url [Boolean] if true, the property value is a URL
        # @return [String] the property value
        def get_property_value(value, is_url: false, &block)
          # Assume hash values are a type/value pair
          if value.is_a?(Hash)
            value_type = value['type']
            value = value['value']
          else
            value_type = nil
          end
          # Apply transformations to string properties
          value = transform_property_value(value, value_type, is_url: is_url) if value.is_a?(String)
          # Return the value or the result of calling the given block on the value
          block ? block.call(value, value_type) : value
        end

        # Removes HTML markup from property values
        # @param value [String] the property value from the Aspire API
        # @param value_type [String] the property type URI from the Aspire API
        # @param is_url [Boolean] if true, the property value is a URL
        # @return [String] the property value
        def transform_property_value(value, value_type = nil, is_url: false)
          if is_url
            # Remove HTML-escaped encodings from URLs but avoid full HTML-stripping
            CGI.unescape_html(value)
          elsif STRIP_HTML
            # Strip HTML preserving block-level whitespace
            # - Loofah seems to preserve &amp; &quot; etc. so we remove these with CGI.unescape_html
            text = CGI.unescape_html(Loofah.fragment(value).to_text)
            # Collapse all runs of whitespace to a single space
            text.gsub!(/\s+/, ' ')
            # Remove leading and trailing whitespace
            text.strip!
            # Return the transformed text
            text
          else
            # Return value as-is
            value
          end
        end

      end


      # Represents a digitisation record in the Aspire API
      class Digitisation < APIObject

        # @!attribute [rw] bundle_id
        #   @return [String] the digitisation bundle ID
        attr_accessor :bundle_id

        # @!attribute [rw] request_id
        #   @return [String] the digitisation request ID
        attr_accessor :request_id

        # @!attribute [rw] request_status
        #   @return [String] the digitisation request status
        attr_accessor :request_status

        # Initialises a new Digitisation instance
        # @param data [Hash] the parsed JSON data hash of the digitisation record
        def initialize(json: nil, ld: nil)
          if json
            self.bundle_id = json['bundleId']
            self.request_id = json['requestId']
            self.request_status = json['requestStatus']
          else
            self.bundle_id = nil
            self.request_id = nil
            self.request_status = nil
          end
        end

        # Returns a string representation of the Digitisation instance (the request ID)
        # @return [String] the string representation of the Digitisation instance
        def to_s
          self.request_id.to_s
        end

      end


      # Selects the primary email address for a user based on rules read from a configuration file
      class EmailSelector

        # @!attribute [rw] config
        #   @return [Hash] the configuration parameter hash
        attr_accessor :config

        # @!attribute [rw] map
        #   @return [Hash<String, String>] a map of email addresses to the canonical (institutional) email address
        attr_accessor :map

        # Initialises a new EmailSelector instance
        # @param filename [String] the name of the configuration file
        # @param map_filename [String] the name of a CSV file containing all known email addresses for a user
        # @return [void]
        def initialize(filename = nil, map_filename = nil)
          self.load_config(filename)
          self.load_map(map_filename)
        end

        # Clears the email map
        # @return [void]
        def clear
          self.map.clear
        end

        # Returns the preferred email address from a list of addresses based on the configuration rules.
        # The email addresses are first matched as provided. If no matches are found, the substitution rules from the
        # configuration are applied and the matching process is repeated on the substituted values. If no matches are
        # found after substitution, the first email in the list is returned.
        # @param emails [Array<String>] the list of email addresses
        # @param use_map [Boolean] if true, use the email map to resolve addresses
        # @param user [LegantoSync::ReadingLists::Aspire::User] the user supplying the list of email addresses
        # @return [String] the preferred email address
        def email(emails = nil, use_map: true, user: nil)
          emails = user.email if emails.nil? && !user.nil?
          # Check the emails as supplied
          result = email_domain(emails)
          return result unless result.nil?
          # If no match was found, apply substitutions and check again
          emails = email_sub(emails)
          result = email_domain(emails)
          # If no match was found after substitutions, check against the email address map
          result = email_map(emails) if result.nil? && use_map
          # If there is still no match, take the first email in the list
          result = emails[0] if result.nil?
          # Return the result
          result
        end

        # Loads the configuration from the specified file
        # @param filename [String] the name of the configuration file
        # @return [void]
        def load_config(filename = nil)
          self.config = {
              domain: [],
              sub: []
          }
          return if filename.nil? || filename.empty?
          CSV.foreach(filename, { col_sep: "\t" }) do |row|
            action = row[0] || ''
            action.strip!
            action.downcase!
            # Skip empty lines and comments
            next if action.nil? || action.empty? || action[0] == '#'
            case action
              when '!', 'domain'
                domain = row[1] || ''
                domain.downcase!
                self.config[:domain].push(domain) unless domain.nil? || domain.empty?
              when '$', 'sub'
                regexp = row[1]
                replacement = row[2] || ''
                self.config[:sub].push([Regexp.new(regexp), replacement]) unless regexp.nil? || regexp.empty?
            end
          end
          nil
        end


        # Loads email mappings from the specified file
        def load_map(filename = nil)
          self.map = {}
          return if filename.nil? || filename.empty?
          delim = /\s*;\s*/
          File.foreach(filename) do |row|
            row.rstrip!
            emails = row.rpartition(',')[2]
            next if emails.nil? || emails.empty?
            # Get all the emails for this user
            emails = emails.split(delim)
            # No need to map a single email to itself
            next if emails.length < 2
            # Get the primary (institutional) email
            primary_email = email(emails, use_map: false)
            # Map all emails to the primary email
            emails.each { |e| self.map[e] = primary_email unless e == primary_email }
          end
        end

        protected

        # Returns the first email address in the list with a domain matching one of the preferred domains from the
        # configuration. The preferred domains are searched in the order they appear in the configuration file, so
        # they should appear in the file in order of preference.
        # @param emails [Array<String>] the list of email addresses
        # @return [String] the preferred email address
        def email_domain(emails)
          domains = self.config[:domain]
          unless domains.empty?
            domains.each do |domain|
              matches = emails.select { |email| email.end_with?(domain) }
              return matches[0] unless matches.empty?
            end
          end
          nil
        end

        # Returns the canonical (institutional) email address for the first address which exists in the email map
        # @param emails [Array<String>] the list of email addresses
        # @return [String] the canonical email address
        def email_map(emails)
          emails.each do |e|
            result = self.map[e]
            unless result.nil? || result.empty?
              return result
            end
          end
          nil
        end

        # Returns a copy of the email list parameter with substitutions applied to each email
        # @param emails [Array<String>] the list of email addresses
        # @return [Array<String>] the list of modified email addresses
        def email_sub(emails)
          subs = self.config[:sub]
          if subs.nil? || subs.empty?
            emails
          else
            emails.map do |email|
              # Apply substitutions to and return a copy of the email
              email_sub = email.slice(0..-1)
              subs.each { |sub| email_sub.gsub!(sub[0], sub[1]) }
              email_sub
            end
          end
        end

      end


      # A factory returning reading list objects given the object's URI
      class Factory

        include Util

        # @!attribute [rw] api
        #   @return [LegantoSync::ReadingLists::Aspire::API] the Aspire API instance used to retrieve data
        attr_accessor :api

        # @!attribute [rw] email_selector
        #   @return [LegantoSync::ReadingLists::Aspire::EmailSelector] the email selector for identifying users'
        #     primary email addresses
        attr_accessor :email_selector

        # @!attribute [rw] ldap_lookup
        #   @return [LegantoSync::ReadingLists::Aspire::LDAPLookup] the LDAP lookup instance for identifying users'
        #     usernames
        attr_accessor :ldap_lookup

        # @!attribute [rw] users
        #   @return [Hash<String, LegantoSync::ReadingLists::Aspire::User>] a hash of user profiles indexed by URI
        attr_accessor :users

        # Initialises a new ReadingListFactory instance
        # @param api [LegantoSync::ReadingLists::Aspire::API] the Aspire API instance used to retrieve data
        # @param users [Hash<String, LegantoSync::ReadingLists::Aspire::User>] a hash mapping user profile URIs to users
        # @return [void]
        def initialize(api, email_selector: nil, ldap_lookup: nil, users: nil)
          self.api = api
          self.email_selector = email_selector
          self.ldap_lookup = ldap_lookup
          self.users = users || {}
        end

        # Returns a new reading list object (ReadingListBase subclass) given its URI
        # @param uri [String] the URI of the object
        # @param parent [LegantoSync::ReadingLists::Aspire::ListObject] the parent reading list object of this object
        # @return [LegantoSync::ReadingLists::Aspire::ListObject] the reading list object
        def get(uri = nil, parent = nil, json: nil, ld: nil)
          return nil if uri.nil? || uri.empty?
          if uri.include?('/items/')
            # Get item data from the parent list (from the JSON API) rather than the Linked Data API
            ListItem.new(uri, self, parent)
          elsif uri.include?('/resources/') && !json.nil?
            # Get resource data from the JSON API rather than the Linked Data API if available
            Resource.new(uri, self, json: json, ld: ld)
          elsif uri.include?('/users/')
            get_user(uri, ld)
          else
            # Get lists, modules, resources and sections from the Linked Data API
            # If the URI is present in the linked data hash, the corresponding data is used. Otherwise, the data is
            # loaded from the linked data API.
            puts(uri)
            ld = self.api.get_json(uri, expand_path: false) if ld.nil? || !ld.has_key?(uri)
            if uri.include?('/lists/')
              List.new(uri, self, parent, json: json, ld: ld)
            elsif uri.include?('/modules/')
              Module.new(uri, self, json: json, ld: ld)
            elsif uri.include?('/resources/')
              Resource.new(uri, self, json: json, ld: ld)
            elsif uri.include?('/sections/')
              ListSection.new(uri, self, parent, json: json, ld: ld)
            else
              nil
            end
          end
        end

        # Returns a new user profile object given its URI
        # User profile instances are stored in a cache indexed by URI. Cache misses trigger a call to the Aspire
        # user profile JSON API.
        # @param uri [String] the URI of the user profile object
        # @return [LegantoSync::ReadingLists::Aspire::User] the user profile object
        def get_user(uri = nil, data = nil)

          # Return the user from the cache if available
         user = self.users[uri]
         return user if user

          # Get user from the JSON API and add to the cache
          #json = self.api.call("users/#{id_from_uri(uri)}")
          #if json
          #  user = User.new(uri, self, self.email_selector, self.ldap_lookup, json: json)
          #  self.users[user.uri] = user
          #  user
          #else
          #  # TODO: this is a hack, just return the URI for now if the lookup fails
          #  uri
          #end
          nil

        end

      end


      # Retrieves user details from LDAP directory
      class LDAPLookup

        # @!attribute [rw] base
        #   @return [String] the root of the LDAP user tree
        attr_accessor :base

        # @!attribute [rw] cache
        #   @return [Hash<String, String>] cached email => user ID lookups
        attr_accessor :cache

        # @!attribute [rw] use_cache
        #   @return [Boolean] if true, cache LDAP responses and use for subsequent searched
        attr_accessor :use_cache

        # Initialises a new LDAPLookup instance
        # @see (LegantoSync::ReadingLists::Aspire::LDAPLookup#open)
        # @return [void]
        def initialize(host, user, password, base, use_cache: false)
          self.base = base
          self.cache = {}
          self.use_cache = use_cache
          open(host, user, password)
        end

        # Clears the cache
        # @return [void]
        def clear
          self.cache.clear
        end

        # Closes the LDAP connection
        # @return [void]
        def close
          @ldap.close if @ldap
          @ldap = nil
        end

        # Returns the username of the user matching the supplied email address
        # @param email [String] the user's email address
        def find(email = nil)

          # Search cache
          if self.use_cache
            uid = self.cache[email]
            return uid if uid
          end

          # Search LDAP for the email address as given
          filter = Net::LDAP::Filter.eq('mail', email)
          @ldap.search(attributes: ['uid'], base: self.base, filter: filter) do |entry|
            uid = get_uid(email, entry)
            return uid if uid
          end

          # The exact email address wasn't found, try the form "username@domain" if the username component looks like
          # a username (assumes that usernames do not contain punctuation)
          user, domain = email.split('@')
          unless user.nil? || user.empty? || user.include?('.')
            filter = Net::LDAP::Filter.eq('uid', user)
            @ldap.search(attributes: ['uid'], base: self.base, filter: filter) do |entry|
              uid = get_uid(email, entry)
              return uid if uid
            end
          end

          # No matches found
          nil

        end

        # Opens the LDAP connection
        # @param host [String] the LDAP server
        # @param user [String] the LDAP bind username
        # @param password [String] the LDAP bind password
        # @return [void]
        def open(host, user = nil, password = nil)
          @ldap = Net::LDAP.new
          @ldap.host = host
          @ldap.port = 389
          @ldap.auth(user, password)
          @ldap.bind
        end

        protected

        # Returns the 'uid' property from an LDAP entry
        # @param email [String] the email address corresponding to the LDAP entry
        # @param ldap_entry [Net::LDAP::Entry] the LDAP entry
        # @return [String] the first value of the 'uid' property
        def get_uid(email, ldap_entry)
          # Get the first uid value (this should always be the canonical username)
          uid = ldap_entry.uid ? ldap_entry.uid[0] : nil
          # Update the cache
          self.cache[email] = uid if uid && self.use_cache
          # Return the uid
          uid
        end

      end


      # The abstract base class of reading list objects (items, lists, sections)
      class ListObject < APIObject

        # The Aspire Linked Data API returns properties of the form "#{KEY_PREFIX}_n" where n is a 1-based numeric index
        # denoting the display order of the property.
        KEY_PREFIX = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#'

        # @!attribute [rw] entries
        #   @return [Array<LegantoSync::ReadingLists::Aspire::ListObject>] the ordered list of child objects
        attr_accessor :entries

        # @!attribute [rw] parent
        #   @return [LegantoSync::ReadingLists::Aspire::ListObject] the parent reading list object of this object
        attr_accessor :parent

        # Initialises a new ReadingListBase instance
        # @param uri [String] the URI of the reading list object (item/list/section)
        # @param factory [LegantoSync::ReadingLists::Aspire::Factory] a factory returning ReadingListBase
        #   subclass instances
        # @param parent [LegantoSync::ReadingLists::Aspire::ListObject] the parent reading list object of this object
        # @param json [Hash] the parsed JSON data hash containing the properties of the ReadingListBase instance
        #   from the Aspire JSON API
        # @param ld [Hash] the parsed JSON data hash containing the properties of the ReadingListBase instance
        #   from the Aspire Linked Data API
        # @return [void]
        def initialize(uri, factory, parent = nil, json: nil, ld: nil)
          super(uri, factory)
          self.parent = parent
          self.entries = self.get_entries(json: json, ld: ld)
        end

        # Iterates over the child reading list objects in display order
        # @yield [entry] passes the child reading list object to the block
        # @yieldparam entry [LegantoSync::ReadingLists::Aspire::ReadingListBase] the reading list object
        def each(&block)
          self.entries.each(&block)
        end

        # Iterates over the child list items in display order (depth-first tree traversal)
        # @yield [entry] passes the list item to the block
        # @yieldparam entry [LegantoSync::ReadingLists::Aspire::ListItem] the reading list item
        # @return [void]
        def each_item(&block)
          each do |entry|
            if entry.is_a?(ListItem)
              # Pass the list item to the block
              yield(entry) if block_given?
            else
              # Iterate the entry's list items
              entry.each_item(&block)
            end
          end
          nil
        end

        # Iterates over the child list sections in display order (depth-first tree traversal)
        # @yield [entry] passes the list section to the block
        # @yieldparam entry [LegantoSync::ReadingLists::Aspire::ListSection] the reading list section
        # @return [void]
        def each_section(&block)
          each do |entry|
            if entry.is_a?(List)
              # Iterate the list's sections
              entry.each_section(&block)
            elsif entry.is_a?(ListSection)
              # Pass the list section to the block
              yield(entry) if block_given?
            end
          end
          nil
        end

        # Returns the number of entries in the reading list object
        # @

        # Returns a list of child reading list objects in display order
        # @param json [Hash] the parsed JSON data hash from the Aspire JSON API
        # @param ld [Hash] the parsed JSON data hash from the Aspire linked data API
        # @return [Array<LegantoSync::ReadingLists::Aspire::ListObject>] the ordered list of child objects
        def get_entries(json: nil, ld: nil)
          entries = []
          data = ld ? ld[self.uri] : nil
          if data
            data.each do |key, value|
              prefix, index = key.split('_')
              entries[index.to_i - 1] = self.factory.get(value[0]['value'], self, ld: ld) if prefix == KEY_PREFIX
            end
          end
          entries
        end

        # Returns the child items of this object in display order
        # @return [Array<LegantoSync::ReadingLists::Aspire::ListItem>] the child reading list items
        def items
          result = []
          each_item { |item| result.push(item) }
          result
        end

        # Returns the number of items in the list
        # @param item_type [Symbol] selects the list entry type to count
        #   :entry = top-level item or section
        #   :item  = list item (default)
        #   :section = top-level section
        # @return [Integer] the number of list entry instances
        def length(item_type = nil)
          item_type ||= :item
          case item_type
            when :entry
              # Return the number of top-level entries (items and sections)
              self.entries.length
            when :item
              # Return the number of list items as the sum of list items in each entry
              self.entries.reduce(0) { |count, entry| count + entry.length(:item) }
            when :section
              # Return the number of top-level sections
              self.sections.length
          end
        end

        # Returns the parent list of this object
        # @return [LegantoSync::ReadingLists::Aspire::List] the parent reading list
        def parent_list
          self.parent_lists[0]
        end

        # Returns the ancestor lists of this object (nearest ancestor first)
        # @return [Array<LegantoSync::ReadingLists::Aspire::List>] the ancestor reading lists
        def parent_lists
          self.parents(List)
        end

        # Returns the parent section of this object
        # @return [LegantoSync::ReadingLists::Aspire::ListSection] the parent reading list section
        def parent_section
          self.parent_sections[0]
        end

        # Returns the ancestor sections of this object (nearest ancestor first)
        # @return [Array<LegantoSync::ReadingLists::Aspire::ListSection>] the ancestor reading list sections
        def parent_sections
          self.parents(ListSection)
        end

        # Returns a list of ancestor reading list objects of this object (nearest ancestor first)
        # Positional parameters are the reading list classes to include in the result. If no classes are specified,
        # all classes are included.
        # @yield [ancestor] passes the ancestor to the block
        # @yieldparam ancestor [LegantoSync::ReadingLists::Aspire::ListObject] the reading list object
        # @yieldreturn [Boolean] if true, include in the ancestor list, otherwise ignore
        def parents(*classes)
          result = []
          ancestor = self.parent
          until ancestor.nil?
            # Filter ancestors by class
            if classes.nil? || classes.empty? || classes.include?(ancestor.class)
              # If a block is given, it must return true for the ancestor to be included
              result.push(ancestor) unless block_given? && !yield(ancestor)
            end
            ancestor = ancestor.parent
          end
          result
        end

        # Returns the child sections of this object
        # @return [Array<LegantoSync::ReadingLists::Aspire::ListSection>] the child reading list sections
        def sections
          self.entries.select { |e| e.is_a?(ListSection) }
        end

      end


      # Represents a reading list item (citation) in the Aspire API
      class ListItem < ListObject

        # @!attribute [rw] digitisation
        #   @return [LegantoSync::ReadingLists::Aspire::Digitisation] the digitisation details for the item
        attr_accessor :digitisation

        # @!attribute [rw] importance
        #   @return [String] the importance of the item
        attr_accessor :importance

        # @!attribute [rw] library_note
        #   @return [String] the internal library note for the item
        attr_accessor :library_note

        # @!attribute [rw] local_control_number
        #   @return [String] the identifier of the resource in the local library management system
        attr_accessor :local_control_number

        # @!attribute [rw] note
        #   @return [String] the public note for the item
        attr_accessor :note

        # @!attribute [rw] resource
        #   @return [LegantoSync::ReadingLists::Aspire::Resource] the resource for the item
        attr_accessor :resource

        # @!attribute [rw] student_note
        #   @return [String] the public note for the item
        attr_accessor :student_note

        # @!attribute [rw] title
        #   @return [String] the title of the item
        attr_accessor :title

        # Initialises a new ListItem instance
        # @param uri [String] the URI of the reading list object (item/list/section)
        # @param factory [LegantoSync::ReadingLists::Aspire::Factory] a factory returning ReadingListBase
        #   subclass instances
        # @param parent [LegantoSync::ReadingLists::Aspire::ListObject] the parent reading list object of this object
        # @param json [Hash] the parsed JSON data hash containing the properties of the ReadingListBase instance
        #   from the Aspire JSON API
        # @param ld [Hash] the parsed JSON data hash containing the properties of the ReadingListBase instance
        #   from the Aspire Linked Data API
        # @return [void]
        def initialize(uri, factory, parent = nil, json: nil, ld: nil)

          super(uri, factory, parent, json: json, ld: ld)

          if json.nil?
            # Get the JSON API item data from the parent list
            owner = self.parent_list
            json = owner && owner.items ? owner.items[uri] : nil
          end

          # item_ld = ld ? ld[uri] : nil

          # The digitisation request
          digitisation_json = json ? json['digitisation'] : nil

          digitisation_ld = nil  # TODO: linked data digitisation - we don't use Talis' digitisation service
          if digitisation_json || digitisation_ld
            digitisation = Digitisation.new(json: digitisation_json, ld: digitisation_ld)
          else
            digitisation = nil
          end

          # The resource
          resource_json = json ? json['resource'] : nil
          if resource_json.is_a?(Array)
            resource_json = resource_json.empty? ? nil : resource_json[0]
            puts("WARNING: selected first resource of #{resource_json}") if resource_json  # TODO: remove once debugged!
          end
          resource = resource_json ? factory.get(resource_json['uri'], json: resource_json) : nil
          #resource_json = json ? json['resource'] : nil
          #resource_uri = get_property('http://purl.org/vocab/resourcelist/schema#resource', item_ld)
          #resource = resource_json # || resource_uri ? factory.get(resource_uri, json: resource_json, ld: ld) : nil

          self.digitisation = digitisation
          self.importance = self.get_property('importance', json)
          self.library_note = self.get_property('libraryNote', json)
          #self.local_control_number = self.get_property('http://lists.talis.com/schema/bibliographic#localControlNumber',
          #                                              item_ld)
          #self.note = self.get_property('http://rdfs.org/sioc/spec/note', item_ld)
          self.local_control_number = self.get_property('lcn', json)
          self.note = self.get_property('note', json)
          self.resource = resource
          self.student_note = self.get_property('studentNote', json)
          self.title = self.get_property('title', json)

        end

        # Returns the length of the list item
        # @see (LegantoSync::ReadingLists::Aspire::ListObject#length)
        def length(item_type = nil)
          item_type ||= :item
          # List items return an item length of 1 to enable summation of list/section lengths
          item_type == :item ? 1 : super(item_type)
        end

        # Returns the resource title or public note if no resource is available
        # @param alt [Symbol] the alternative if no resource is available
        #   :library_note or :private_note = the library note
        #   :note = the student note, or the library note if no student note is available
        #   :public_note, :student_note = the student note
        #   :uri = the list item URI
        # @return [String] the resource title or alternative
        def title(alt = nil)
          # Return the resource title if available, otherwise return the specified alternative
          return self.resource.title || @title if self.resource
          case alt
            when :library_note, :private_note
              self.library_note || nil
            when :note
              self.student_note || self.note || self.library_note || nil
            when :public_note, :student_note
              self.student_note || self.note || nil
            when :uri
              self.uri
            else
              nil
          end
        end

        # Returns a string representation of the ListItem instance (the citation title or note)
        # @return [String] the string representation of the ListItem instance
        def to_s
          self.title(:public_note).to_s
        end

      end


      # Represents a reading list section in the Aspire API
      class ListSection < ListObject

        # @!attribute [rw] description
        #   @return [String] the reading list section description
        attr_accessor :description

        # @!attribute [rw] name
        #   @return [String] the reading list section name
        attr_accessor :name

        # Initialises a new ListSection instance
        # @param uri [String] the URI of the reading list object (item/list/section)
        # @param factory [LegantoSync::ReadingLists::Aspire::Factory] a factory returning ReadingListBase
        #   subclass instances
        # @param parent [LegantoSync::ReadingLists::Aspire::ListObject] the parent reading list object of this object
        # @param json [Hash] the parsed JSON data hash containing the properties of the ReadingListBase instance
        #   from the Aspire JSON API
        # @param ld [Hash] the parsed JSON data hash containing the properties of the ReadingListBase instance
        #   from the Aspire Linked Data API
        # @return [void]
        def initialize(uri, factory, parent = nil, json: nil, ld: nil)
          super(uri, factory, parent, json: json, ld: ld)
          section_ld = ld[uri]
          self.description = self.get_property('http://purl.org/vocab/resourcelist/schema#description', section_ld)
          self.name = self.get_property('http://rdfs.org/sioc/spec/name', section_ld)
        end

        # Returns a string representation of the ListSection instance (the section name)
        # @return [String] the string representation of the ListSection instance
        def to_s
          self.name || super
        end

      end


      # Represents a reading list in the Aspire API
      class List < ListObject

        # @!attribute [rw] created
        #   @return [DateTime] the creation timestamp of the list
        attr_accessor :created

        # @!attribute [rw] creator
        #   @return [Array<LegantoSync::ReadingLists::Aspire::User>] the list of creators of the reading list
        attr_accessor :creator

        # @!attribute [rw] description
        #   @return [String] the description of the list
        attr_accessor :description

        # @!attribute [rw] items
        #   @return [Hash<String, LegantoSync::ReadingLists::Aspire::ListItem>] a hash of ListItems indexed by item URI
        attr_accessor :items

        # @!attribute [rw] last_published
        #   @return [DateTime] the timestamp of the most recent list publication
        attr_accessor :last_published

        # @!attribute [rw] last_updated
        #   @return [DateTime] the timestamp of the most recent list update
        attr_accessor :last_updated

        # @!attribute [rw] list_history
        #   @return [Hash] the parsed JSON data from the Aspire list history JSON API
        attr_accessor :list_history

        # @!attribute [rw] modules
        #   @return [Array<LegantoSync::ReadingLists::Aspire::Module>] the list of modules referencing this list
        attr_accessor :modules

        # @!attribute [rw] name
        #   @return [String] the reading list name
        attr_accessor :name

        # @!attribute [rw] owner
        #   @return [LegantoSync::ReadingLists::Aspire::User] the list owner
        attr_accessor :owner

        # @!attribute [rw] publisher
        #   @return [LegantoSync::ReadingLists::Aspire::User] the list publisher
        attr_accessor :publisher

        # @!attribute [rw] time_period
        #   @return [LegantoSync::ReadingLists::Aspire::TimePeriod] the time period covered by the list
        attr_accessor :time_period

        # @!attribute [rw] uri
        #   @return [String] the URI of the reading list
        attr_accessor :uri

        # Initialises a new List instance
        # @param uri [String] the URI of the reading list object (item/list/section)
        # @param factory [LegantoSync::ReadingLists::Aspire::Factory] a factory returning ReadingListBase
        #   subclass instances
        # @param parent [LegantoSync::ReadingLists::Aspire::ListObject] the parent reading list object of this object
        # @param json [Hash] the parsed JSON data hash containing the properties of the ReadingListBase instance
        #   from the Aspire JSON API
        # @param ld [Hash] the parsed JSON data hash containing the properties of the ReadingListBase instance
        #   from the Aspire Linked Data API
        # @return [void]
        def initialize(uri, factory, parent = nil, json: nil, ld: nil)

          # Set properties from the Reading Lists API
          # - this must be called before the superclass constructor so that item details are available
          json = self.set_data(uri, factory, json)

          super(uri, factory, parent, json: json, ld: ld)

          # Set properties from the Linked Data API data
          set_linked_data(uri, factory, ld)

        end

        # Returns the number of items in the list
        # @see (LegantoSync::ReadingLists::Aspire::ListObject#length)
        def length(item_type = nil)
          item_type ||= :item
          # The item length of a list is the length of the items property, avoiding the need to sum list entry lengths
          item_type == :item ? self.items.length : super(item_type)
        end

        # Retrieves the list details and history from the Aspire list details/history JSON API
        # @param uri [String] the URI of the reading list object (item/list/section)
        # @param factory [LegantoSync::ReadingLists::Aspire::Factory] a factory returning ReadingListBase
        #   subclass instances
        # @param json [Hash] the parsed JSON data hash containing the properties of the reading list object from the
        #    Aspire JSON API
        # @return [void]
        def set_data(uri, factory, json = nil)

          api = factory.api
          list_id = self.id_from_uri(uri)

          # Default values
          self.modules = nil
          self.name = nil
          self.time_period = nil

          # Get the list details
          puts("  - list details API: #{list_id}")
          options = { bookjacket: 1, draft: 1, editions: 1, history: 0 }
          if json.nil?
            json = api.call("lists/#{list_id}", **options) # do |response, data|
            #   File.open("#{dir}/details.json", 'w') { |f| f.write(JSON.pretty_generate(data)) }
            # end
          end

          # Get the list history
          puts("  - list history API: #{list_id}")
          self.list_history = api.call("lists/#{list_id}/history") # do |response, data|
          #   File.open("#{dir}/history.json", 'w') { |f| f.write(JSON.pretty_generate(data)) }
          # end

          # A hash mapping item URI to item
          self.items = {}

          if json
            json['items'].each { |item| self.items[item['uri']] = item } if json['items']
            self.modules = json['modules'].map { |m| Module.new(m['uri'], factory, json: m) } if json['modules']
            self.name = json['name']
            period = json['timePeriod']
            self.time_period = period ? TimePeriod.new(period['uri'], factory, json: period) : nil
          end

          # Return the parsed JSON data from the Aspire list details JSON API
          json

        end

        # Sets reading list properties from the Aspire linked data API
        # @return [void]
        def set_linked_data(uri, factory, ld = nil)
          list_data = ld[self.uri]
          has_creator = self.get_property('http://rdfs.org/sioc/spec/has_creator', list_data, single: false) || []
          has_owner = self.get_property('http://purl.org/vocab/resourcelist/schema#hasOwner', list_data, single: false) || []
          published_by = self.get_property('http://purl.org/vocab/resourcelist/schema#publishedBy', list_data)
          self.created = self.get_date('http://purl.org/vocab/resourcelist/schema#created', list_data)
          self.creator = has_creator.map { |uri| factory.get(uri, ld: ld) }
          self.description = self.get_property('http://purl.org/vocab/resourcelist/schema#description', list_data)
          self.last_published = self.get_date('http://purl.org/vocab/resourcelist/schema#lastPublished', list_data)
          self.last_updated = self.get_date('http://purl.org/vocab/resourcelist/schema#lastUpdated', list_data)
          if self.modules.nil?
            mods = self.get_property('http://purl.org/vocab/resourcelist/schema#usedBy', list_data, single: false)
            self.modules = mods.map { |uri| factory.get(uri, ld: ld) } if mods
          end
          unless self.name
            self.name = self.get_property('http://rdfs.org/sioc/spec/name', list_data)
          end
          self.owner = has_owner.map { |uri| self.factory.get(uri, ld: ld) }
          self.publisher = self.factory.get(published_by, ld: ld)
          nil
        end

        # Returns a string representation of the List instance (the reading list name)
        # @return [String] the string representation of the List instance
        def to_s
          self.name || super
        end

      end


      # Represents a module in the Aspire API
      class Module < APIObject

        # @!attribute [rw] code
        #   @return [String] the module code
        attr_accessor :code

        # @!attribute [rw] name
        #   @return [String] the module name
        attr_accessor :name

        # Initialises a new Module instance
        def initialize(uri, factory, json: nil, ld: nil)
          super(uri, factory)
          self.code = get_property('code', json) || get_property('http://purl.org/vocab/aiiso/schema#code', ld)
          self.name = get_property('name', json) || get_property('http://putl.org/vocab/aiiso/schema#name', ld)
        end

        # Returns a string representation of the Module instance (the module name)
        # @return [String] the string representation of the Module instance
        def to_s
          self.name.to_s || super
        end

      end


      # Represents a resource in the Aspire API
      class Resource < APIObject

        CITATION_PROPERTIES = %w{
          authors book_jacket_url date doi edition edition_data eissn has_part is_part_of isbn10 isbn13 isbns issn
          issue issued latest_edition local_control_number online_resource page page_end page_start
          place_of_publication publisher title type url volume
        }

        # @!attribute [rw] authors
        #   @return [Array<String>] the list of authors of the resource
        attr_accessor :authors

        # @!attribute [rw] book_jacket_url
        #   @return [String] the book jacket image URL
        attr_accessor :book_jacket_url

        # @!attribute [rw] date
        #   @return [String] the date of publication
        attr_accessor :date

        # @!attribute [rw] doi
        #   @return [String] the DOI for the resource
        attr_accessor :doi

        # @!attribute [rw] edition
        #   @return [String] the edition
        attr_accessor :edition

        # @!attribute [rw] edition_data
        #   @return [Boolean] true if edition data is available
        attr_accessor :edition_data

        # @!attribute [rw] eissn
        #   @return [String] the electronic ISSN for the resource
        attr_accessor :eissn

        # @!attribute [rw] has_part
        #   @return [Array<LegantoSync::ReadingLists::Aspire::Resource>] the resources contained by this resource
        attr_accessor :has_part

        # @!attribute [rw] is_part_of
        #   @return [Array<LegantoSync::ReadingLists::Aspire::Resource>] the resources containing this resource
        attr_accessor :is_part_of

        # @!attribute [rw] isbn10
        #   @return [String] the 10-digit ISBN for the resource
        attr_accessor :isbn10

        # @!attribute [rw] isbn13
        #   @return [String] the 13-digit ISBN for the resource
        attr_accessor :isbn13

        # @!attribute [rw] isbns
        #   @return [Array<String>] the list of ISBNs for the resource
        attr_accessor :isbns

        # @!attribute [rw] issn
        #   @return [Array<String>] the ISSN for the resource
        attr_accessor :issn

        # @!attribute [rw] issue
        #   @return [String] the issue
        attr_accessor :issue

        # @!attribute [rw] issued
        #   @return [String] the issue date
        attr_accessor :issued

        # @!attribute [rw] latest_edition
        #   @return [Boolean] true if this is the latest edition
        attr_accessor :latest_edition

        # @!attribute [rw] local_control_number
        #   @return [String] the local control number (in the library management system) of the resource
        attr_accessor :local_control_number

        # @!attribute [rw] online_resource
        #   @return [Boolean] true if this is an online resource
        attr_accessor :online_resource

        # @!attribute [rw] page
        #   @return [String] the page range
        attr_accessor :page

        # @!attribute [rw] page_end
        #   @return [String] the end page
        attr_accessor :page_end

        # @!attribute [rw] page_start
        #   @return [String] the start page
        attr_accessor :page_start

        # @!attribute [rw] place_of_publication
        #   @return [String] the place of publication
        attr_accessor :place_of_publication

        # @!attribute [rw] publisher
        #   @return [String] the publisher
        attr_accessor :publisher

        # @!attribute [rw] title
        #   @return [String] the title of the resource
        attr_accessor :title

        # @!attribute [rw] type
        #   @return [String] the type of the resource
        attr_accessor :type

        # @!attribute [rw] url
        #   @return [String] the URL of the resource
        attr_accessor :url

        # @!attribute [rw] volume
        #   @return [String] the volume
        attr_accessor :volume

        # Initialises a new Resource instance
        # @param json [Hash] the parsed JSON data hash for the resource from the Aspire JSON API
        # @param ld [Hash] the parsed JSON data hash for the resource from the Aspire linked data API
        # @return [void]
        def initialize(uri = nil, factory = nil, json: nil, ld: nil)
          uri = json ? json['uri'] : nil if uri.nil?
          super(uri, factory)
          if json
            has_part = json['hasPart']
            is_part_of = json['isPartOf']
            self.authors = get_property('authors', json, single: false)
            self.book_jacket_url = get_property('bookjacketURL', json)
            self.date = get_property('date', json)
            self.doi = get_property('doi', json)
            self.edition = get_property('edition', json)
            self.edition_data = get_property('editionData', json)
            self.eissn = get_property('eissn', json)
            self.has_part = has_part ? factory.get(uri, json: has_part) : nil
            self.is_part_of = is_part_of ? factory.get(uri, json: is_part_of) : nil
            self.isbn10 = get_property('isbn10', json)
            self.isbn13 = get_property('isbn13', json)
            self.isbns = get_property('isbns', json, single: false)
            self.issn = get_property('issn', json)
            self.issue = get_property('issue', json)
            self.issued = json ? json['issued'] : nil  # TODO
            self.latest_edition = get_property('latestEdition', json)
            self.local_control_number = get_property('lcn', json)
            self.online_resource = get_property('onlineResource', json) ? true : false
            self.page = get_property('page', json)
            self.page_end = get_property('pageEnd', json)
            self.page_start = get_property('pageStart', json)
            self.place_of_publication = get_property('placeOfPublication', json)
            self.publisher = get_property('publisher', json)
            self.title = get_property('title', json)
            self.type = get_property('type', json)
            self.url = get_property('url', json, is_url: true)
            self.volume = get_property('volume', json)
          end
        end

        # Handles citation_<property>() accessor calls by proxying to the parent resource if no instance value is set.
        # The <property> accessor for this instance is called first, and if this returns nil and there is a parent
        # resource (is_part_of), the property accessor of the parent is called. This continues up through the
        # ancestor resources until a value is found.
        # @param method_name [Symbol] the method name
        # Positional and keyword arguments are passed to the property accessor
        def method_missing(method_name, *args, &block)

          # Catch methods beginning with citation_... and ignore others
          super unless method_name.to_s.start_with?('citation_')

          # Remove the 'citation_' prefix to get the property name, fail if it's not a valid property
          property = method_name[9..-1]
          super if property.nil? || property.empty?
          super unless CITATION_PROPERTIES.include?(property) && self.respond_to?(property)

          # Try the resource's property first
          value = self.public_send(property, *args, &block)
          return value unless value.nil?

          # Delegate to the parent resource's property if it exists
          # - call the parent's citation_<property> rather than <property> to delegate up the ancestor chain.
          if self.is_part_of
            value = self.is_part_of.public_send(method_name, *args, &block)
            return value unless value.nil?
          end

          # Otherwise return nil
          nil

        end

        # Returns the title of the journal article associated with this resource
        # @return [String, nil] the journal article title or nil if not applicable
        def article_title
          self.part_title_by_type('Article')
        end

        # Returns the title of the book associated with this resource
        # @return [String, nil] the book title or nil if not applicable
        def book_title
          self.part_of_title_by_type('Book')
        end

        # Returns the title of the book chapter associated with this resource
        # @return [String, nil] the book chapter title or nil if not applicable
        def chapter_title
          self.part_title_by_type('Chapter')
        end

        # Returns the title of the resource as expected by the Alma reading list loader
        # (Article = article title, book = book title, other = resource title)
        # @return [String] the citation title
        def citation_title
          self.article_title || self.book_title || self.title
        end

        # Returns the title of the journal associated with this resource
        # @return [String, nil] the journal title or nil if not applicable
        def journal_title
          self.part_of_title_by_type('Journal')
        end

        # Returns the title of the part (book chapter, journal article etc.)
        # @return [String] the title of the part
        def part_title
          self.has_part && self.has_part.title ? self.has_part.title : nil
        end

        # Returns the title of the parent resource (book, journal etc.)
        # @return [String] the title of the parent resource
        def part_of_title
          self.is_part_of && self.is_part_of.title ? self.is_part_of.title : nil
        end

        # Returns a string representation of the resource (the title)
        # @return [String] the string representation of the resource
        def to_s
          self.title
        end

        protected

        # Returns the title of the part
        # @param resource_type [String] the type of the resource
        # @return [String] the title of the part
        def part_title_by_type(resource_type)
          if self.type == resource_type
            self.title
          elsif self.has_part && self.has_part.type == resource_type
            self.has_part.title
          else
            nil
          end
        end

        # Returns the title of the parent resource (book, journal etc.)
        # @return [String] the title of the parent resource
        def part_of_title_by_type(resource_type)
          if self.type == resource_type
            self.title
          elsif self.is_part_of && self.is_part_of.type == resource_type
            self.is_part_of.title
          else
            nil
          end
        end

      end


      # Represents the time period covered by a reading list in the Aspire API
      class TimePeriod < APIObject

        include LUSI::API::Core::Util

        # @!attribute [rw] active
        #   @return [Boolean] true if the time period is currently active
        attr_accessor :active

        # @!attribute [rw] end_date
        #   @return [Date] the end of the time period
        attr_accessor :end_date

        # @!attribute [rw] start_date
        #   @return [Date] the start of the time period
        attr_accessor :start_date

        # @!attribute [rw] title
        #   @return [String] the title of the time period
        attr_accessor :title

        # Initialises a new TimePeriod instance
        def initialize(uri, factory, json: nil, ld: nil)
          super(uri, factory)
          if json
            self.active = get_property('active', json)
            self.end_date = get_date('endDate', json)
            self.start_date = get_date('startDate', json)
            self.title = get_property('title', json)
          else
            self.active = nil
            self.end_date = nil
            self.start_date = nil
            self.title = nil
          end
        end

        # Returns a string representation of the TimePeriod instance (the title)
        # @return [String] the string representation of the TimePeriod instance
        def to_s
          self.title.to_s
        end

        # Returns the academic year containing this time period
        # @return [Integer, nil] the year containing this time period, or nil if unspecified
        def year
          result = self.title.split('-')[0]
          result ? result.to_i : nil
        end

      end


      # Represents a user profile in the Aspire API
      class User < APIObject

        # @!attribute [rw] email
        #   @return [Array<String>] the list of email addresses for the user
        attr_accessor :email

        # @!attribute [rw] first_name
        #   @return [String] the user's first name
        attr_accessor :first_name

        # @!attribute [rw] primary_email
        #   @return [String] the user's primary (institutional) email address, selected from the list of addresses
        attr_accessor :primary_email

        # @!attribute [rw] role
        #   @return [Array<String>] the list of Aspire roles associated with the user
        attr_accessor :role

        # @!attribute [rw] surname
        #   @return [String] the user's last name
        attr_accessor :surname

        # @!attribute [rw] username
        #   @return [String] the user's institutional username
        attr_accessor :username

        # Initialises a new User instance
        # @param uri [String] the URI of the user profile
        # @param factory [LegantoSync::ReadingLists::Aspire::Factory] a factory returning User instances
        # @param email_selector [LegantoSync::ReadingLists::Aspire::EmailSelector] an email selector for identifying
        #   the user's primary email address
        # @param ldap_lookup [LegantoSync::ReadingLists::Aspire::LDAPLookup] an LDAP lookup instance for identifying
        #   the user's institutional username
        # @param json [Hash] the parsed JSON hash of user profile data from the Aspire user profile JSON API
        # @param ld [Hash] the parsed JSON hash of user profile data from the Aspire linked data API
        # @return [void]
        def initialize(uri, factory, email_selector = nil, ldap_lookup = nil, json: nil, ld: nil)
          super(uri, factory)
          if json
            self.first_name = json['firstName']
            self.role = json['role']
            self.surname = json['surname']
            # Set the email, primary_email and username properties from the email address list
            set_email(json['email'], email_selector, ldap_lookup)
          else
            self.first_name = nil
            self.role = []
            self.surname = nil
            self.email = []
            self.primary_email = nil
            self.username = nil
          end
        end

        # Sets the email, primary_email and username properties given a list of email addresses
        # @param email [Array<String>] the email address list
        # @param email_selector [LegantoSync::ReadingLists::Aspire::EmailSelector] an email selector for identifying
        #   the user's primary email address
        # @param ldap_lookup [LegantoSync::ReadingLists::Aspire::LDAPLookup] an LDAP lookup instance for identifying
        #   the user's institutional username
        def set_email(email = nil, email_selector = nil, ldap_lookup = nil)
          self.email = email || []
          if email_selector
            # Get the primary email address from the address list
            self.primary_email = email_selector.email(self.email)
            # Get the username from the primary email address
            if ldap_lookup and self.primary_email
              self.username = ldap_lookup.find(self.primary_email)
            else
              self.username = nil
            end
          else
            self.primary_email = nil
            self.username = nil
          end
        end

        # Returns a string representation of the user profile (the user's name and primary email address)
        # @return [String] the string representation of the user profile
        def to_s
          email_address = self.primary_email
          if email_address.nil? || email_address.empty?
            "#{self.first_name} #{self.surname}"
          else
            "#{self.first_name} #{self.surname} <#{email_address}>"
          end
        end

      end


      # Implements a hash of User instances indexed by URI
      # The hash can be populated from a CSV file following the Aspire "All User Profiles" report format
      class UserLookup < Hash

        # @!attribute [rw] email_selector
        #   @return [LegantoSync::ReadingLists::Aspire::EmailSelector] the email selector for resolving primary email
        #     addresses
        attr_accessor :email_selector

        # @!attribute [rw] ldap_lookup
        #   @return [LegantoSync::ReadingLists::Aspire::LDAPLookup] the LDAP lookup service for resolving usernames
        attr_accessor :ldap_lookup

        # Initialises a new UserLookup instance
        # @see (Hash#initialize)
        # @param filename [String] the filename of the CSV file used to populate the hash
        # @return [void]
        def initialize(*args, email_selector: nil, filename: nil, ldap_lookup: nil, **kwargs, &block)
          super(*args, **kwargs, &block)
          self.email_selector = email_selector
          self.ldap_lookup = ldap_lookup
          self.load(filename) if filename
        end

        # Populates the hash from a CSV file following the Aspire "All User Profiles" report format
        # @param filename [String] the filename of the CSV file
        # @return [void]
        def load(filename = nil)

          delim = /\s*;\s*/
          CSV.foreach(filename) do |row|

            # Recreate the Aspire user profile JSON API response from the CSV record
            uri = row[3]
            data = {
                'email' => (row[4] || '').split(delim),
                'firstName' => row[0],
                'role' => (row[7] || '').split(delim),
                'surname' => row[1],
                'uri' => row[3]
            }

            # Create the user and set the primary email and username
            user = User.new(uri, nil, self.email_selector, self.ldap_lookup, json: data)

            # Add the user to the lookup table
            self[uri] = user

          end

          nil

        end

      end

    end
  end
end