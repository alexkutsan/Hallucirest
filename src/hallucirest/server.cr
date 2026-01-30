require "http/server"
require "./http_app"
require "./config"
require "./runner"
require "./log"

module Hallucirest
  class Server
    getter host : String
    getter port : Int32

    def initialize(@host : String, @port : Int32, @app : HttpApp)
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
          raise ex
        end
      end

      server.bind_tcp(@host, @port)
      Log.info { "listening on http://#{@host}:#{@port}" }
      server.listen
    end
  end
end
