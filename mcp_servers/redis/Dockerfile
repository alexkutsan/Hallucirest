FROM crystallang/crystal:1.19

WORKDIR /app

COPY shard.yml ./
RUN shards install

COPY . .
RUN shards build --release

EXPOSE 8001

CMD ["./bin/redis_mcp_server"]
