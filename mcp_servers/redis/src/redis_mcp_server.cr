require "http/server"
require "json"
require "uuid"
require "redis"

module RedisMcpServer
  VERSION          = "0.1.0"
  PROTOCOL_VERSION = "2024-11-05"
  MCP_SESSION_ID   = "Mcp-Session-Id"

  # Redis client abstraction
  module RedisClient
    abstract def get(key : String) : String?
    abstract def set(key : String, value : String) : String?
    abstract def del(key : String) : Int64
    abstract def hset(key : String, field : String, value : String) : Int64
    abstract def hdel(key : String, field : String) : Int64
    abstract def hgetall(key : String) : Hash(String, String)
  end

  class RealRedisClient
    include RedisClient

    def initialize(@redis : Redis)
    end

    def get(key : String) : String?
      @redis.get(key)
    end

    def set(key : String, value : String) : String?
      @redis.set(key, value)
    end

    def del(key : String) : Int64
      @redis.del(key)
    end

    def hset(key : String, field : String, value : String) : Int64
      @redis.hset(key, field, value)
    end

    def hdel(key : String, field : String) : Int64
      @redis.hdel(key, field)
    end

    def hgetall(key : String) : Hash(String, String)
      @redis.hgetall(key)
    end
  end

  record Tool,
    name : String,
    description : String,
    input_schema : Hash(String, JSON::Any),
    output_schema : Hash(String, JSON::Any)? = nil

  struct ToolResult
    getter structured_content : Hash(String, JSON::Any)
    getter? is_error : Bool

    def initialize(@structured_content, @is_error = false)
    end
  end

  class Server
    @redis : RedisClient
    @sessions = {} of String => Bool
    @mutex = Mutex.new
    @tools : Hash(String, Tool)
    @tool_handlers : Hash(String, Proc(Hash(String, JSON::Any), ToolResult))

    getter bound_address : Socket::IPAddress?
    @http_server : HTTP::Server?

    def initialize(@bind_host : String, @port : Int32, redis : RedisClient? = nil)
      @redis = redis || build_redis_client
      @http_server = nil
      @bound_address = nil
      @tools = {} of String => Tool
      @tool_handlers = {} of String => Proc(Hash(String, JSON::Any), ToolResult)

      register_tools
    end

    def bound_port : Int32?
      @bound_address.try(&.port)
    end

    def start : Nil
      server = HTTP::Server.new do |context|
        handle_http(context)
      end

      @http_server = server
      @bound_address = server.bind_tcp(@bind_host, @port)
      server.listen
    end

    def stop : Nil
      @http_server.try(&.close)
    end

    # --- HTTP Handling ---

    private def handle_http(context : HTTP::Server::Context) : Nil
      req = context.request
      res = context.response

      if req.method == "GET" && req.path == "/health"
        json_response(res, 200, {"ok" => JSON::Any.new(true)})
        return
      end

      if req.path != "/mcp"
        json_response(res, 404, {"error" => JSON::Any.new("not found")})
        return
      end

      case req.method
      when "POST"
        handle_mcp_post(context)
      when "DELETE"
        handle_mcp_delete(context)
      else
        res.status_code = 405
        res.print("Method Not Allowed")
      end
    end

    private def handle_mcp_post(context : HTTP::Server::Context) : Nil
      req = context.request
      res = context.response

      # Validate Accept header
      accept = req.headers["Accept"]?
      unless accept && accept.includes?("application/json")
        jsonrpc_error(res, nil, -32600, "Not Acceptable: Client must accept application/json")
        return
      end

      # Validate Content-Type
      content_type = req.headers["Content-Type"]?
      unless content_type == "application/json"
        jsonrpc_error(res, nil, -32600, "Unsupported Media Type: Content-Type must be application/json")
        return
      end

      # Parse body
      body = req.body.try(&.gets_to_end) || ""
      if body.empty?
        jsonrpc_error(res, nil, -32700, "Parse error: empty body")
        return
      end

      begin
        json = JSON.parse(body)
      rescue
        jsonrpc_error(res, nil, -32700, "Parse error: invalid JSON")
        return
      end

      # Handle request
      id = json["id"]?
      method = json["method"]?.try(&.as_s?)
      params = json["params"]?.try(&.as_h?) || {} of String => JSON::Any

      unless method
        jsonrpc_error(res, id, -32600, "Invalid Request: missing method")
        return
      end

      session_id = req.headers[MCP_SESSION_ID]?

      case method
      when "initialize"
        handle_initialize(res, id, params)
      when "ping"
        handle_ping(res, id, session_id)
      when "tools/list"
        handle_tools_list(res, id, session_id)
      when "tools/call"
        handle_tools_call(res, id, session_id, params)
      else
        jsonrpc_error(res, id, -32601, "Method not found: #{method}")
      end
    end

    private def handle_mcp_delete(context : HTTP::Server::Context) : Nil
      session_id = context.request.headers[MCP_SESSION_ID]?
      unless session_id
        context.response.status_code = 400
        context.response.print "Missing session"
        return
      end

      deleted = @mutex.synchronize { @sessions.delete(session_id) }
      if deleted
        context.response.status_code = 200
      else
        context.response.status_code = 404
        context.response.print "Session not found"
      end
    end

    # --- MCP Methods ---

    private def handle_initialize(res : HTTP::Server::Response, id : JSON::Any?, params : Hash(String, JSON::Any))
      session_id = UUID.random.to_s
      @mutex.synchronize { @sessions[session_id] = true }

      res.headers[MCP_SESSION_ID] = session_id
      jsonrpc_result(res, id, {
        "protocolVersion" => JSON::Any.new(PROTOCOL_VERSION),
        "capabilities"    => JSON::Any.new({"tools" => JSON::Any.new({} of String => JSON::Any)}),
        "serverInfo"      => JSON::Any.new({
          "name"    => JSON::Any.new("redis_mcp_server"),
          "version" => JSON::Any.new(VERSION),
        }),
      })
    end

    private def handle_ping(res : HTTP::Server::Response, id : JSON::Any?, session_id : String?)
      sid = session_id
      unless valid_session?(sid)
        jsonrpc_error(res, id, -32600, "Invalid session")
        return
      end

      # valid_session? implies sid is present
      res.headers[MCP_SESSION_ID] = sid.as(String)
      jsonrpc_result(res, id, {} of String => JSON::Any)
    end

    private def handle_tools_list(res : HTTP::Server::Response, id : JSON::Any?, session_id : String?)
      sid = session_id
      unless valid_session?(sid)
        jsonrpc_error(res, id, -32600, "Invalid session")
        return
      end

      res.headers[MCP_SESSION_ID] = sid.as(String)

      tools_array = @tools.values.map do |tool|
        tool_json = {
          "name"        => JSON::Any.new(tool.name),
          "description" => JSON::Any.new(tool.description),
          "inputSchema" => JSON::Any.new(tool.input_schema),
        }
        if os = tool.output_schema
          tool_json["outputSchema"] = JSON::Any.new(os)
        end
        JSON::Any.new(tool_json)
      end

      jsonrpc_result(res, id, {"tools" => JSON::Any.new(tools_array)})
    end

    private def handle_tools_call(res : HTTP::Server::Response, id : JSON::Any?, session_id : String?, params : Hash(String, JSON::Any))
      sid = session_id
      unless valid_session?(sid)
        jsonrpc_error(res, id, -32600, "Invalid session")
        return
      end

      res.headers[MCP_SESSION_ID] = sid.as(String)

      tool_name = params["name"]?.try(&.as_s?)
      unless tool_name
        jsonrpc_error(res, id, -32602, "Invalid params: missing tool name")
        return
      end

      handler = @tool_handlers[tool_name]?
      unless handler
        jsonrpc_error(res, id, -32602, "Unknown tool: #{tool_name}")
        return
      end

      arguments = params["arguments"]?.try(&.as_h?) || {} of String => JSON::Any

      begin
        result = handler.call(arguments)
        jsonrpc_tool_result(res, id, result)
      rescue ex
        jsonrpc_error(res, id, -32603, "Tool error: #{ex.message}")
      end
    end

    private def valid_session?(session_id : String?) : Bool
      return false unless session_id
      @mutex.synchronize { @sessions.has_key?(session_id) }
    end

    # --- JSON-RPC Response Helpers ---

    private def json_response(res : HTTP::Server::Response, status : Int32, data : Hash(String, JSON::Any))
      res.status_code = status
      res.content_type = "application/json"
      res.print(data.to_json)
    end

    private def jsonrpc_result(res : HTTP::Server::Response, id : JSON::Any?, result : Hash(String, JSON::Any))
      res.status_code = 200
      res.content_type = "application/json"
      response = {
        "jsonrpc" => JSON::Any.new("2.0"),
        "id"      => id || JSON::Any.new(nil),
        "result"  => JSON::Any.new(result),
      }
      res.print(response.to_json)
    end

    private def jsonrpc_tool_result(res : HTTP::Server::Response, id : JSON::Any?, result : ToolResult)
      res.status_code = 200
      res.content_type = "application/json"

      content_item = {
        "type" => JSON::Any.new("text"),
        "text" => JSON::Any.new(tool_result_text(result)),
      }

      result_hash = {
        "content"           => JSON::Any.new([JSON::Any.new(content_item)]),
        "structuredContent" => JSON::Any.new(result.structured_content),
        "isError"           => JSON::Any.new(result.is_error?),
      }

      response = {
        "jsonrpc" => JSON::Any.new("2.0"),
        "id"      => id || JSON::Any.new(nil),
        "result"  => JSON::Any.new(result_hash),
      }
      res.print(response.to_json)
    end

    private def tool_result_text(result : ToolResult) : String
      sc = result.structured_content

      if v = sc["value"]?
        v.as_s
      elsif deleted = sc["deleted"]?
        deleted.as_i64.to_s
      elsif created = sc["created"]?
        created.as_i64.to_s
      elsif ok = sc["ok"]?
        ok.as_bool.to_s
      elsif error = sc["error"]?
        error.as_s
      else
        sc.to_json
      end
    end

    private def jsonrpc_error(res : HTTP::Server::Response, id : JSON::Any?, code : Int32, message : String)
      res.status_code = 200
      res.content_type = "application/json"
      response = {
        "jsonrpc" => JSON::Any.new("2.0"),
        "id"      => id || JSON::Any.new(nil),
        "error"   => JSON::Any.new({
          "code"    => JSON::Any.new(code.to_i64),
          "message" => JSON::Any.new(message),
        }),
      }
      res.print(response.to_json)
    end

    # --- Tool Registration ---

    private def register_tool(tool : Tool, &handler : Hash(String, JSON::Any) -> ToolResult)
      @tools[tool.name] = tool
      @tool_handlers[tool.name] = handler
    end

    private def error_result(message : String) : ToolResult
      ToolResult.new({"error" => JSON::Any.new(message)}, is_error: true)
    end

    private def structured_result(data : Hash(String, JSON::Any), is_error : Bool = false) : ToolResult
      ToolResult.new(data, is_error)
    end

    private def register_tools
      register_redis_get
      register_redis_set
      register_redis_del
      register_redis_hset
      register_redis_hdel
      register_redis_hgetall
    end

    private def register_redis_get : Nil
      register_tool(Tool.new(
        name: "redis_get",
        description: "Get a value by key",
        input_schema: {
          "type"       => JSON::Any.new("object"),
          "properties" => JSON::Any.new({
            "key" => JSON::Any.new({"type" => JSON::Any.new("string")}),
          }),
          "required" => JSON::Any.new(["key"].map { |s| JSON::Any.new(s) }),
        },
        output_schema: {
          "type"       => JSON::Any.new("object"),
          "properties" => JSON::Any.new({
            "value" => JSON::Any.new({"type" => JSON::Any.new("string")}),
          }),
        }
      )) do |args|
        key = args["key"]?.try(&.as_s?)
        unless key
          next error_result("missing argument: key")
        end

        begin
          value = @redis.get(key)
          if value
            structured_result({"value" => JSON::Any.new(value)})
          else
            error_result("key not found")
          end
        rescue ex
          error_result(ex.message || "Redis error")
        end
      end
    end

    private def register_redis_set : Nil
      register_tool(Tool.new(
        name: "redis_set",
        description: "Set a value for a key",
        input_schema: {
          "type"       => JSON::Any.new("object"),
          "properties" => JSON::Any.new({
            "key"   => JSON::Any.new({"type" => JSON::Any.new("string")}),
            "value" => JSON::Any.new({"type" => JSON::Any.new("string")}),
          }),
          "required" => JSON::Any.new(["key", "value"].map { |s| JSON::Any.new(s) }),
        },
        output_schema: {
          "type"       => JSON::Any.new("object"),
          "properties" => JSON::Any.new({
            "ok" => JSON::Any.new({"type" => JSON::Any.new("boolean")}),
          }),
        }
      )) do |args|
        key = args["key"]?.try(&.as_s?)
        value = args["value"]?.try(&.as_s?)
        unless key && value
          next error_result("missing argument: key/value")
        end

        begin
          @redis.set(key, value)
          structured_result({"ok" => JSON::Any.new(true)})
        rescue ex
          error_result(ex.message || "Redis error")
        end
      end
    end

    private def register_redis_del : Nil
      register_tool(Tool.new(
        name: "redis_del",
        description: "Delete a key",
        input_schema: {
          "type"       => JSON::Any.new("object"),
          "properties" => JSON::Any.new({
            "key" => JSON::Any.new({"type" => JSON::Any.new("string")}),
          }),
          "required" => JSON::Any.new(["key"].map { |s| JSON::Any.new(s) }),
        },
        output_schema: {
          "type"       => JSON::Any.new("object"),
          "properties" => JSON::Any.new({
            "deleted" => JSON::Any.new({"type" => JSON::Any.new("integer")}),
          }),
        }
      )) do |args|
        key = args["key"]?.try(&.as_s?)
        unless key
          next error_result("missing argument: key")
        end

        begin
          count = @redis.del(key)
          structured_result({"deleted" => JSON::Any.new(count)})
        rescue ex
          error_result(ex.message || "Redis error")
        end
      end
    end

    private def register_redis_hset : Nil
      register_tool(Tool.new(
        name: "redis_hset",
        description: "Set a field in a hash",
        input_schema: {
          "type"       => JSON::Any.new("object"),
          "properties" => JSON::Any.new({
            "key"   => JSON::Any.new({"type" => JSON::Any.new("string")}),
            "field" => JSON::Any.new({"type" => JSON::Any.new("string")}),
            "value" => JSON::Any.new({"type" => JSON::Any.new("string")}),
          }),
          "required" => JSON::Any.new(["key", "field", "value"].map { |s| JSON::Any.new(s) }),
        },
        output_schema: {
          "type"       => JSON::Any.new("object"),
          "properties" => JSON::Any.new({
            "created" => JSON::Any.new({"type" => JSON::Any.new("integer")}),
          }),
        }
      )) do |args|
        key = args["key"]?.try(&.as_s?)
        field = args["field"]?.try(&.as_s?)
        value = args["value"]?.try(&.as_s?)
        unless key && field && value
          next error_result("missing argument: key/field/value")
        end

        begin
          count = @redis.hset(key, field, value)
          structured_result({"created" => JSON::Any.new(count)})
        rescue ex
          error_result(ex.message || "Redis error")
        end
      end
    end

    private def register_redis_hdel : Nil
      register_tool(Tool.new(
        name: "redis_hdel",
        description: "Delete a field from a hash",
        input_schema: {
          "type"       => JSON::Any.new("object"),
          "properties" => JSON::Any.new({
            "key"   => JSON::Any.new({"type" => JSON::Any.new("string")}),
            "field" => JSON::Any.new({"type" => JSON::Any.new("string")}),
          }),
          "required" => JSON::Any.new(["key", "field"].map { |s| JSON::Any.new(s) }),
        },
        output_schema: {
          "type"       => JSON::Any.new("object"),
          "properties" => JSON::Any.new({
            "deleted" => JSON::Any.new({"type" => JSON::Any.new("integer")}),
          }),
        }
      )) do |args|
        key = args["key"]?.try(&.as_s?)
        field = args["field"]?.try(&.as_s?)
        unless key && field
          next error_result("missing argument: key/field")
        end

        begin
          count = @redis.hdel(key, field)
          structured_result({"deleted" => JSON::Any.new(count)})
        rescue ex
          error_result(ex.message || "Redis error")
        end
      end
    end

    private def register_redis_hgetall : Nil
      register_tool(Tool.new(
        name: "redis_hgetall",
        description: "Get all fields and values from a hash",
        input_schema: {
          "type"       => JSON::Any.new("object"),
          "properties" => JSON::Any.new({
            "key" => JSON::Any.new({"type" => JSON::Any.new("string")}),
          }),
          "required" => JSON::Any.new(["key"].map { |s| JSON::Any.new(s) }),
        },
        output_schema: {
          "type"                 => JSON::Any.new("object"),
          "additionalProperties" => JSON::Any.new({"type" => JSON::Any.new("string")}),
        }
      )) do |args|
        key = args["key"]?.try(&.as_s?)
        unless key
          next error_result("missing argument: key")
        end

        begin
          values = @redis.hgetall(key)
          data = values.transform_values { |v| JSON::Any.new(v) }
          structured_result(data)
        rescue ex
          error_result(ex.message || "Redis error")
        end
      end
    end

    private def build_redis_client : RedisClient
      url = ENV["REDIS_URL"]?
      unless url
        raise "REDIS_URL is not set"
      end
      RealRedisClient.new(Redis.new(url: url))
    end
  end
end
