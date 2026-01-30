config := "config.yml"
bin_dir := "./bin"

# Default recipe
_default:
  @just --list

install:
  shards install

build: install
  shards build

run: build
  ./bin/hallucirest --config {{config}}

test: test-root

test-root:
  crystal spec

test-redis:
  env CRYSTAL_CACHE_DIR=mcp_servers/redis/.crystal_cache crystal spec mcp_servers/redis/spec/redis_mcp_server_spec.cr

test-mongo:
  env CRYSTAL_CACHE_DIR=mcp_servers/mongo/.crystal_cache crystal spec mcp_servers/mongo/spec/mongo_mcp_server_spec.cr

test-all: test-root test-redis test-mongo

lint: install
  ./bin/ameba

format:
  crystal tool format src spec mcp_servers/redis/src mcp_servers/redis/spec mcp_servers/mongo/src mcp_servers/mongo/spec

format-check:
  crystal tool format --check src spec mcp_servers/redis/src mcp_servers/redis/spec mcp_servers/mongo/src mcp_servers/mongo/spec

secrets-scan:
  trufflehog git file://. --fail --no-update

clean:
  rm -rf .crystal
