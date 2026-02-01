require "log"

require "./mongo_mcp_server"

# Redirect all logs to stderr (stdout must be pure JSON-RPC for MCP stdio protocol)
Log.setup do |c|
  c.bind "*", :info, Log::IOBackend.new(io: STDERR)
end

MongoMcpServer::Server.new.run
