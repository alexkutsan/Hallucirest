require "http/server"
require "json"
require "mcp"
require "redis"

module RedisMcpServer
  VERSION = "0.1.0"

  class Server
    MCP_SESSION_ID_HEADER = MCP::Server::StreamableHttpServerTransport::MCP_SESSION_ID

    @redis : Redis
    @mcp_server : MCP::Server::Server
    @mutex = Mutex.new
    @transports = {} of String => MCP::Server::StreamableHttpServerTransport

    def initialize(@bind_host : String, @port : Int32)
      @redis = build_redis_client

      @mcp_server = MCP::Server::Server.new(
        MCP::Protocol::Implementation.new(name: "redis_mcp_server", version: VERSION),
        MCP::Server::ServerOptions.new(
          capabilities: MCP::Protocol::ServerCapabilities.new.with_tools
        )
      )

      register_tools(@mcp_server)
    end

    def start : Nil
      server = HTTP::Server.new do |context|
        handle_http(context)
      end

      server.bind_tcp(@bind_host, @port)
      server.listen
    end

    private def handle_http(context : HTTP::Server::Context) : Nil
      req = context.request
      res = context.response

      if req.method == "GET" && req.path == "/health"
        res.status_code = 200
        res.content_type = "application/json"
        res.print(JSON.build { |j| j.object { j.field "ok", true } })
        return
      end

      if req.path != "/mcp"
        res.status_code = 404
        res.content_type = "application/json"
        res.print(JSON.build { |j| j.object { j.field "error", "not found" } })
        return
      end

      case req.method
      when "POST"
        handle_mcp_post(context)
      when "GET"
        handle_mcp_get(context)
      when "DELETE"
        handle_mcp_delete(context)
      else
        res.status_code = 405
        res.print("Method Not Allowed")
      end
    end

    private def handle_mcp_post(context : HTTP::Server::Context) : Nil
      session_id = context.request.headers[MCP_SESSION_ID_HEADER]?

      transport = if sid = session_id
                    @mutex.synchronize { @transports[sid]? }
                  else
                    MCP::Server::StreamableHttpServerTransport.new(true, true)
                  end

      unless transport
        context.response.status_code = HTTP::Status::BAD_REQUEST.code
        context.response.puts "Invalid request or session"
        return
      end

      transport.on_close do
        if sid = transport.session_id
          sid_str = sid.not_nil!
          @mutex.synchronize { @transports.delete(sid_str) }
        end
      end

      @mcp_server.connect(transport)
      transport.handle_post_request(context)

      if sid = transport.session_id
        sid_str = sid.not_nil!
        @mutex.synchronize { @transports[sid_str] = transport }
      end
    end

    private def handle_mcp_get(context : HTTP::Server::Context) : Nil
      session_id = context.request.headers[MCP_SESSION_ID_HEADER]?
      transport = session_id ? @mutex.synchronize { @transports[session_id]? } : nil

      unless transport
        context.response.status_code = HTTP::Status::BAD_REQUEST.code
        context.response.puts "Invalid session"
        return
      end

      MCP::SSE.upgrade_response(context.response) do |conn|
        session = MCP::Server::ServerSSESession.new(conn)
        transport.handle_get_request(context, session)
      end
    end

    private def handle_mcp_delete(context : HTTP::Server::Context) : Nil
      session_id = context.request.headers[MCP_SESSION_ID_HEADER]?
      unless session_id
        context.response.status_code = HTTP::Status::BAD_REQUEST.code
        context.response.puts "Missing session"
        return
      end

      transport = @mutex.synchronize { @transports.delete(session_id) }
      unless transport
        context.response.status_code = HTTP::Status::NOT_FOUND.code
        context.response.puts "Session not found"
        return
      end

      transport.handle_delete_request(context)
    end

    private def register_tools(server : MCP::Server::Server) : Nil
      server.add_tool(
        name: "redis_get",
        description: "Get a value by key",
        input_schema: MCP::Protocol::Tool::Input.new(
          properties: {
            "key" => JSON::Any.new({"type" => JSON::Any.new("string")}),
          },
          required: ["key"]
        )
      ) do |request|
        key = request.arguments.try(&.["key"]?).try(&.as_s?)
        unless key
          next tool_result(["missing argument: key"], is_error: true)
        end

        begin
          value = @redis.get(key)
          tool_result([value || ""], is_error: value.nil?)
        rescue ex
          tool_result([ex.message || "Redis error"], is_error: true)
        end
      end

      server.add_tool(
        name: "redis_set",
        description: "Set a value for a key",
        input_schema: MCP::Protocol::Tool::Input.new(
          properties: {
            "key"   => JSON::Any.new({"type" => JSON::Any.new("string")}),
            "value" => JSON::Any.new({"type" => JSON::Any.new("string")}),
          },
          required: ["key", "value"]
        )
      ) do |request|
        key = request.arguments.try(&.["key"]?).try(&.as_s?)
        value = request.arguments.try(&.["value"]?).try(&.as_s?)
        unless key && value
          next tool_result(["missing argument: key/value"], is_error: true)
        end

        begin
          @redis.set(key, value)
          tool_result(["OK"], is_error: false)
        rescue ex
          tool_result([ex.message || "Redis error"], is_error: true)
        end
      end

      server.add_tool(
        name: "redis_del",
        description: "Delete a key",
        input_schema: MCP::Protocol::Tool::Input.new(
          properties: {
            "key" => JSON::Any.new({"type" => JSON::Any.new("string")}),
          },
          required: ["key"]
        )
      ) do |request|
        key = request.arguments.try(&.["key"]?).try(&.as_s?)
        unless key
          next tool_result(["missing argument: key"], is_error: true)
        end

        begin
          deleted_count = @redis.del(key)
          tool_result([deleted_count.to_s], is_error: false)
        rescue ex
          tool_result([ex.message || "Redis error"], is_error: true)
        end
      end
    end

    private def tool_result(content : Array(String), is_error : Bool = false) : MCP::Protocol::CallToolResult
      blocks = content.map { |c| MCP::Protocol::TextContentBlock.new(c).as(MCP::Protocol::ContentBlock) }
      MCP::Protocol::CallToolResult.new(content: blocks, is_error: is_error)
    end

    private def build_redis_client : Redis
      url = ENV["REDIS_URL"]?
      unless url
        raise "REDIS_URL is required"
      end

      Redis.new(url: url)
    end
  end
end

bind_host = ENV["REDIS_MCP_BIND"]? || "0.0.0.0"
port = (ENV["REDIS_MCP_PORT"]? || "8001").to_i

RedisMcpServer::Server.new(bind_host, port).start
