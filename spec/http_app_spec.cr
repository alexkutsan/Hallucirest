require "./spec_helper"
require "http/client"
require "json"

require "../src/hallucirest/http_app"

module Hallucirest
  class FakeRunner < Runner
    getter last_prompt : String?

    def initialize(@value : String)
    end

    def run(prompt : String) : String
      @last_prompt = prompt
      "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nhello from runner"
    end
  end

  describe HttpApp do
    it "proxies any request to the runner and returns raw HTTP" do
      runner = FakeRunner.new("ok")
      app = HttpApp.new(runner)

      io = IO::Memory.new
      request = HTTP::Request.new("GET", "/about")
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      app.call(context)
      response.close

      runner.last_prompt.should_not be_nil
      runner.last_prompt.try(&.includes?("GET /about HTTP/1.1")).should be_true

      io.to_s.includes?("HTTP/1.1 200").should be_true
      io.to_s.includes?("hello from runner").should be_true
    end
  end
end
