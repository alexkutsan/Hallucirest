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

    private struct ParsedRawResponse
      getter status_code : Int32
      getter headers : HTTP::Headers
      getter body : String

      def initialize(@status_code : Int32, @headers : HTTP::Headers, @body : String)
      end
    end

    private def apply_raw_http_response(response : HTTP::Server::Response, raw : String) : Nil
      parsed = parse_raw_http_response(raw)
      unless parsed
        response.status_code = 502
        response.content_type = "text/plain"
        response.print(raw)
        return
      end

      response.status_code = parsed.status_code
      parsed.headers.each do |k, v|
        response.headers[k] = v
      end

      response.print(parsed.body)
    end

    private def parse_raw_http_response(raw : String) : ParsedRawResponse?
      return nil if raw.empty?

      sep = raw.index("\r\n\r\n")
      newline = "\r\n"
      if sep.nil?
        sep = raw.index("\n\n")
        newline = "\n"
      end
      return nil if sep.nil?

      head = raw[0, sep]
      body = raw[(sep + (newline == "\r\n" ? 4 : 2)), raw.bytesize - (sep + (newline == "\r\n" ? 4 : 2))]?
      body ||= ""

      lines = head.split(newline)
      return nil if lines.empty?

      status_line = lines[0]
      m = status_line.match(/^HTTP\/\d+\.\d+\s+(\d{3})\b/)
      return nil unless m

      status_code = m[1].to_i
      headers = HTTP::Headers.new

      lines[1..].each do |line|
        next if line.empty?
        idx = line.index(':')
        return nil unless idx
        key = line[0, idx]
        value = line[(idx + 1), line.bytesize - (idx + 1)].lstrip
        headers[key] = value
      end

      ParsedRawResponse.new(status_code, headers, body)
    end
  end
end
