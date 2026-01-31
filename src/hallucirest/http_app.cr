require "http/server"
require "json"
require "./runner"
require "./log"

module Hallucirest
  class HttpApp
    def initialize(@runner : Runner)
    end

    def call(context : HTTP::Server::Context) : Nil
      request = context.request
      response = context.response

      start = Time.utc

      prompt = serialize_request(request)

      begin
        raw = @runner.run(prompt)
        apply_raw_http_response(response, raw)
      rescue ex
        Log.error(exception: ex) { "runner error" }
        response.status_code = 500
        response.content_type = "text/plain"
        response.print(ex.message || "internal error")
      end

      Log.info { "#{request.method} #{request.path} -> #{response.status_code} (#{(Time.utc - start).total_milliseconds}ms)" }
    end

    private def serialize_request(request : HTTP::Request) : String
      io = IO::Memory.new
      io << request.method << " " << request.resource << " HTTP/1.1\r\n"

      request.headers.each do |k, v|
        io << k << ": " << v << "\r\n"
      end

      io << "\r\n"

      body = request.body
      if body
        io << body.gets_to_end
      end

      io.to_s
    end

    private def apply_raw_http_response(response : HTTP::Server::Response, raw : String) : Nil
      io = IO::Memory.new(raw)
      parsed = HTTP::Client::Response.from_io(io, ignore_body: false)

      response.status_code = parsed.status_code
      parsed.headers.each do |k, v|
        response.headers[k] = v
      end
      response.print(parsed.body)
    rescue ex
      response.status_code = 502
      response.content_type = "text/plain"
      response.print(raw)
    end
  end
end
