# coding: utf-8
require "em-proxy"

module HttpProxy
  # Public: The connection class for handling requests
  class Connection < EventMachine::ProxyServer::Connection
    # Public: The backends list
    #
    # Examples
    #
    # HttpProxy::Connection.setup_backend(:one, host: "0.0.0.0", port: 9292)
    # HttpProxy::Connection.setup_backend(:two, host: "0.0.0.0", port: 9292)
    # HttpProxy::Connection.backends # => {one: {host: ...}, two: {host: ...}}
    #
    # Returns Hash
    def self.backends
      @backends || raise(RuntimeError, "Backends list is empty")
    end

    # Public: Add new backend to the backends list
    #
    # name    - [Symbol|String] the backend uid
    # options - Hash the backend connection options
    #           :host         - String the host of backend
    #           :port         - [String|Fixnum] the port of backend
    #           :relay_client - boolean the fast backward flag
    #
    # Returns nothing
    def self.setup_backend(name, options)
      @backends ||= Hash.new
      @backends[name.to_sym] = options
    end

    # Public: The request headers parser
    #
    # Returns HttpProxy::HeadersParser
    def headers
      @headers
    end

    # See HttpProxy::Connection::backends
    def backends
      Connection.backends
    end

    # See HttpProxy::Connection::setup_backend
    def backend(name, options)
      Connection.setup_backend(name.to_sym, options)
    end

    # Public: Route request to specific backend
    #
    # backend - [Symbol|String|Hash] the backend for routing
    #           Hash
    #             :host - String the backend host
    #             :port - [String|Fixnum] the backend port
    #
    # Returns nothing
    def route_to(backend)
      @selected_backend = backend.is_a?(String) ? backend.to_sym : backend
    end

    # Public: Attach block of code for error handling before connection will be closed
    #
    # block - [Block|Proc] the block of code for handle errors
    #
    # Examples
    #
    # HttpProxy::Proxy.start(host: "0.0.0.0", port: 9292) do |proxy|
    #   proxy.process do
    #     proxy.route_to host: "unknown.host", port: 1254
    #   end
    #
    #   proxy.fallback do |error, backend|
    #     p "An error has occured"
    #     p error, backend
    #   end
    # end
    #
    # Returns nothing
    def fallback(&block)
      @fallback = block
    end

    # Public: Process request
    #
    # name  - Symbol the pre-processing method (default: :raw)
    #         :raw     - process with raw headers
    #         :header  - process with parsed headers if specific header key exists
    #         :headers - process with parsed headers
    # args  - Zero or more arguments of all types
    # block - [Block|Proc] the block of code for handle pre-processing
    #
    # Examples
    #
    # HttpProxy::Proxy.start(host: "0.0.0.0", port: 9292) do |proxy|
    #   # simple request pre-processing
    #   proxy.process do
    #     proxy.close_connection
    #   end
    #
    #   # request pre-processing with raw headers
    #   proxy.process do |raw_headers|
    #     p raw_headers
    #     proxy.close_connection
    #   end
    #
    #   # request pre-processing with parsed headers
    #   proxy.process :headers do |headers|
    #     p headers
    #     proxy.close_connection
    #   end
    #
    #   # request pre-processing with parsed headers containing "User" key
    #   proxy.process :header, "User" do |value|
    #     p value
    #     proxy.close_connection
    #   end
    # end
    #
    # Returns nothing
    def process(name = :raw, *args, &block)
      case name
      when :headers then process_with_headers(&block)
      when :header then process_with_header(*args, &block)
      when :raw then process_with_raw(*args, &block)
      else
        raise TypeError, "Unknown pre-processing type"
      end
    end

    private
    # Public: Process request with raw headers
    #
    # block - [Block|Proc] the block of code for request processing
    #
    # Returns nothing
    def process_with_raw(&block)
      on_data do |raw|
        failsafe do
          yield raw

          if_present(@selected_backend) do
            setup_server(@selected_backend)
            raw
          end
        end
      end
    end

    # Public: Process request with parsed headers
    #
    # block - [Block|Proc] the block of code for request processing
    #
    # Returns nothing
    def process_with_headers(&block)
      @headers = HeadersParser.new
      @headers.process do |headers|
        failsafe do
          yield headers

          if_present(@selected_backend) do
            setup_server(@selected_backend)
            relay_to_servers(@headers.buffer)
          end
        end
      end
    end

    # Public: Process request with parsed headers only if headers has specific key
    #
    # key   - String the specific header key
    # block - [Block|Proc] the block of code for request processing
    #
    # Returns nothing
    def process_with_header(key, &block)
      process_with_headers do |headers|
        if_present(headers[key]) do
          yield headers[key]
        end
      end
    end

    # Internal: Yield block of code if something present or close connection
    #
    # something - Object :)
    #
    # Returns nothing
    def if_present(something)
      something ? yield : close_connection
    end

    # Internal: Wrap code execution in rescue block. If error occur call fallback block
    # if it's defined and close connection
    #
    # Returns nothing
    def failsafe
      begin
        yield
      rescue Exception => error
        raise if @fallback.nil?

        @fallback.call(error, @selected_backend)

        close_connection
      end
    end

    # Internal: Setup backend for em-proxy
    #
    # backend - [Symbol|Hash] the name of backend or the backend options
    #           Hash
    #             :host - String the backend host
    #             :port - [String|Fixnum] the backend port
    #
    # Returns nothing
    def setup_server(backend)
      backend.is_a?(Hash) ? server(:noname, backend)
                          : server(backend, backends[backend])
    end
  end
end
