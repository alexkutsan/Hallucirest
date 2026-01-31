require "http/server"
require "./http_app"
require "./config"
require "./runner"
require "./log"

module Hallucirest
  class Server
    getter host : String
    getter port : Int32

    getter bound_address : Socket::IPAddress?

    @server : HTTP::Server?

    def initialize(@host : String, @port : Int32, @app : HttpApp)
      @server = nil
      @bound_address = nil
    end

    def self.build(config : AppConfig, runner : Runner) : self
      app = HttpApp.new(runner)
      new(config.bind_host, config.port, app)
    end

    def start : Nil
      server = HTTP::Server.new do |context|
        begin
          @app.call(context)
        rescue ex
          Log.error(exception: ex) { "unhandled exception" }

          response = context.response
          response.status_code = 500
          response.content_type = "text/plain"
          response.print(ex.message || "internal error")
        end
      end

      @server = server

      @bound_address = server.bind_tcp(@host, @port)
      Log.info { "listening on http://#{@host}:#{@port}" }
      server.listen
    end

    def bound_port : Int32?
      @bound_address.try(&.port)
    end

    def stop : Nil
      @server.try(&.close)
    end
  end
end
