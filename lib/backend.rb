require_relative './backend/local_logger'
require_relative './backend/remote_net'

module Backend
  module_function

  def for_net(net)
    net.local_net? ? LocalLogger : RemoteNet
  end

  def remote
    RemoteNet
  end

  class Logger
    PasswordIncorrectError = Class.new(StandardError)
    NotAuthorizedError = Class.new(StandardError)
    CouldNotCloseNetError = Class.new(StandardError)
    CouldNotCreateNetError = Class.new(StandardError)
    CouldNotFindNetAfterCreationError = Class.new(StandardError)

    def initialize(net_info, user: nil, require_logger_auth: false)
      backend_class = Backend.for_net(net_info.net)
      @backend = backend_class.new(net_info, user:, require_logger_auth:)
    end

    def self.start_logging(net_info, password:, user:)
      backend_class = Backend.for_net(net_info.net)
      backend_class.start_logging(net_info, password:, user:)
    end

    def self.create_net!(**kwargs)
      LocalLogger.create_net!(**kwargs)
    end

    def method_missing(method_name, *args, **kwargs, &block)
      @backend.public_send(method_name, *args, **kwargs, &block)
    end

    def respond_to_missing?(method_name, include_private = false)
      @backend.respond_to?(method_name, include_private) || super
    end
  end
end
