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

  describe "Server integration" do
    it "proxies any path over TCP" do
      # Bind ephemeral port by binding to 0, then reading the actual port.
      runner = FakeRunner2.new
      app = HttpApp.new(runner)

      server = HTTP::Server.new { |ctx| app.call(ctx) }
      address = server.bind_tcp("127.0.0.1", 0)

      ch = Channel(Nil).new
      spawn do
        server.listen
      ensure
        ch.send(nil)
      end

      begin
        port = address.port
        client = HTTP::Client.new("127.0.0.1", port)
        resp = client.get("/about")
        resp.status_code.should eq(200)
        resp.body.includes?("integration ok").should be_true
      ensure
        server.close
      end
    end
  end
end
