require "./spec_helper"
require "http/client"
require "json"

require "../src/hallucirest/server"

module Hallucirest
  class FakeRunner2 < Runner
    def run(prompt : String) : String
      "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nintegration ok"
    end
  end

  class ExplodingRunner < Runner
    def run(prompt : String) : String
      raise "boom"
    end
  end

  class ExplodingApp < HttpApp
    def initialize
      super(ExplodingRunner.new)
    end

    def call(context : HTTP::Server::Context) : Nil
      raise "unhandled"
    end
  end

  describe "Server integration" do
    it "builds server from config" do
      config = AppConfig.new(
        bind_host: "127.0.0.1",
        port: 8080,
        openai_api_key: "k",
        openai_api_host: "https://api.openai.com",
        openai_model: "gpt-4o",
        max_iterations: 1,
        timeout_seconds: 1,
        mcp_servers: ({} of String => AgentKit::MCPServerConfig),
      )

      server = Server.build(config, FakeRunner2.new)
      server.host.should eq("127.0.0.1")
      server.port.should eq(8080)
    end

    it "proxies any path over TCP using Hallucirest::Server" do
      runner = FakeRunner2.new
      app = HttpApp.new(runner)
      server = Server.new("127.0.0.1", 0, app)

      ch = Channel(Nil).new
      spawn do
        server.start
      ensure
        ch.send(nil)
      end

      begin
        until port = server.bound_port
          sleep 10.milliseconds
        end

        client = HTTP::Client.new("127.0.0.1", port)
        resp = client.get("/about")
        resp.status_code.should eq(200)
        resp.body.includes?("integration ok").should be_true
      ensure
        server.stop
      end
    end

    it "returns 500 when app raises unhandled exception" do
      server = Server.new("127.0.0.1", 0, ExplodingApp.new)

      ch = Channel(Nil).new
      spawn do
        server.start
      ensure
        ch.send(nil)
      end

      begin
        until port = server.bound_port
          sleep 10.milliseconds
        end

        client = HTTP::Client.new("127.0.0.1", port)
        resp = client.get("/boom")
        resp.status_code.should eq(500)
        resp.body.includes?("unhandled").should be_true
      ensure
        server.stop
      end
    end
  end
end
