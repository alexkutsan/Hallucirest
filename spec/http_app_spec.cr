require "./spec_helper"
require "http/client"
require "json"

require "../src/hallucirest/http_app"

module Hallucirest
  class FakeRunner < Runner
    getter last_prompt : String?
    property response_value : String

    def initialize(@response_value : String = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nhello from runner")
    end

    def run(prompt : String) : String
      @last_prompt = prompt
      @response_value
    end
  end

  describe HttpApp do
    it "proxies any request to the runner and returns raw HTTP" do
      runner = FakeRunner.new
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

    it "returns 502 for invalid HTTP response" do
      runner = FakeRunner.new("not a valid http response")
      app = HttpApp.new(runner)

      io = IO::Memory.new
      request = HTTP::Request.new("GET", "/test")
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      app.call(context)
      response.close

      io.to_s.includes?("HTTP/1.1 502").should be_true
      io.to_s.includes?("not a valid http response").should be_true
    end

    it "handles empty body correctly" do
      runner = FakeRunner.new("HTTP/1.1 204 No Content\r\nX-Custom: value\r\n\r\n")
      app = HttpApp.new(runner)

      io = IO::Memory.new
      request = HTTP::Request.new("DELETE", "/resource")
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      app.call(context)
      response.close

      io.to_s.includes?("HTTP/1.1 204").should be_true
    end

    it "handles multiple headers" do
      runner = FakeRunner.new("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Request-Id: abc123\r\n\r\n{\"ok\":true}")
      app = HttpApp.new(runner)

      io = IO::Memory.new
      request = HTTP::Request.new("GET", "/api")
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      app.call(context)
      response.close

      output = io.to_s
      output.includes?("HTTP/1.1 200").should be_true
      output.includes?("{\"ok\":true}").should be_true
    end

    it "handles LF-only line endings" do
      runner = FakeRunner.new("HTTP/1.1 200 OK\nContent-Type: text/plain\n\nLF body")
      app = HttpApp.new(runner)

      io = IO::Memory.new
      request = HTTP::Request.new("GET", "/lf")
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      app.call(context)
      response.close

      output = io.to_s
      output.includes?("HTTP/1.1 200").should be_true
      output.includes?("LF body").should be_true
    end
  end
end
