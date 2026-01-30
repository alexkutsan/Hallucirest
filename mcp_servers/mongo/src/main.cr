require "json"
require "cryomongo"
require "mcp"
require "log"

# Redirect all logs to stderr (stdout must be pure JSON-RPC for MCP stdio protocol)
Log.setup do |c|
  c.bind "*", :info, Log::IOBackend.new(io: STDERR)
end

module MongoMcpServer
  VERSION = "0.1.0"

  class Server
    @client : Mongo::Client

    def initialize
      @client = build_mongo_client
    end

    def run : Nil
      server = MCP::Server::Server.new(
        MCP::Protocol::Implementation.new(name: "mongo_mcp_server", version: VERSION),
        MCP::Server::ServerOptions.new(
          capabilities: MCP::Protocol::ServerCapabilities.new.with_tools
        )
      )

      register_tools(server)

      MCP::StdioRunner.new(server).run
    end

    private def register_tools(server : MCP::Server::Server) : Nil
      server.add_tool(
        name: "mongo_find",
        description: "List documents in a collection",
        input_schema: MCP::Protocol::Tool::Input.new(
          properties: {
            "db"         => JSON::Any.new({"type" => JSON::Any.new("string")}),
            "collection" => JSON::Any.new({"type" => JSON::Any.new("string")}),
          },
          required: ["db", "collection"]
        )
      ) do |request|
        db = request.arguments.try(&.["db"]?).try(&.as_s?)
        coll = request.arguments.try(&.["collection"]?).try(&.as_s?)

        unless db && coll
          next tool_result(["missing argument: db/collection"], is_error: true)
        end

        begin
          collection = @client[db][coll]
          docs = collection.find.to_a
          json_items = docs.map(&.to_json)
          tool_result(["[#{json_items.join(",")}]"], is_error: false)
        rescue ex
          tool_result([ex.message || "Mongo error"], is_error: true)
        end
      end

      server.add_tool(
        name: "mongo_insert_one",
        description: "Insert one document into a collection",
        input_schema: MCP::Protocol::Tool::Input.new(
          properties: {
            "db"         => JSON::Any.new({"type" => JSON::Any.new("string")}),
            "collection" => JSON::Any.new({"type" => JSON::Any.new("string")}),
            "document"   => JSON::Any.new({"type" => JSON::Any.new("object")}),
          },
          required: ["db", "collection", "document"]
        )
      ) do |request|
        db = request.arguments.try(&.["db"]?).try(&.as_s?)
        coll = request.arguments.try(&.["collection"]?).try(&.as_s?)
        doc = request.arguments.try(&.["document"]?)

        unless db && coll && doc
          next tool_result(["missing argument: db/collection/document"], is_error: true)
        end

        begin
          collection = @client[db][coll]
          bson = BSON.from_json(doc.to_json)
          collection.insert_one(bson)
          tool_result(["OK"], is_error: false)
        rescue ex
          tool_result([ex.message || "Mongo error"], is_error: true)
        end
      end

      server.add_tool(
        name: "mongo_delete_all",
        description: "Delete all documents from a collection",
        input_schema: MCP::Protocol::Tool::Input.new(
          properties: {
            "db"         => JSON::Any.new({"type" => JSON::Any.new("string")}),
            "collection" => JSON::Any.new({"type" => JSON::Any.new("string")}),
          },
          required: ["db", "collection"]
        )
      ) do |request|
        db = request.arguments.try(&.["db"]?).try(&.as_s?)
        coll = request.arguments.try(&.["collection"]?).try(&.as_s?)

        unless db && coll
          next tool_result(["missing argument: db/collection"], is_error: true)
        end

        begin
          collection = @client[db][coll]
          result = collection.delete_many(BSON.from_json("{}"))
          deleted = result.try(&.n) || 0
          tool_result([deleted.to_s], is_error: false)
        rescue ex
          tool_result([ex.message || "Mongo error"], is_error: true)
        end
      end
    end

    private def tool_result(content : Array(String), is_error : Bool = false) : MCP::Protocol::CallToolResult
      blocks = content.map { |c| MCP::Protocol::TextContentBlock.new(c).as(MCP::Protocol::ContentBlock) }
      MCP::Protocol::CallToolResult.new(content: blocks, is_error: is_error)
    end

    private def build_mongo_client : Mongo::Client
      url = ENV["MONGO_URL"]?
      unless url
        raise "MONGO_URL is required"
      end

      Mongo::Client.new(url)
    end
  end
end

MongoMcpServer::Server.new.run
