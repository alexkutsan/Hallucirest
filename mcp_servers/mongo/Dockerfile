FROM crystallang/crystal:1.19

WORKDIR /app

COPY shard.yml ./
RUN shards install

COPY . .
RUN shards build --release

CMD ["./bin/mongo_mcp_server"]
