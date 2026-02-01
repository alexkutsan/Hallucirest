require "./redis_mcp_server"

bind_host = ENV["REDIS_MCP_BIND"]? || "0.0.0.0"
port = (ENV["REDIS_MCP_PORT"]? || "8001").to_i

RedisMcpServer::Server.new(bind_host, port).start
