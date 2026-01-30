FROM crystallang/crystal:1.19

WORKDIR /app

COPY shard.yml shard.lock ./
RUN shards install

COPY . .
RUN shards build --release

# Build mongo_mcp_server (stdio MCP server)
WORKDIR /app/mcp_servers/mongo
RUN shards install && shards build --release
RUN cp bin/mongo_mcp_server /app/bin/

WORKDIR /app

EXPOSE 8080

CMD ["./bin/hallucirest", "--config", "/app/docker/config.yml"]
