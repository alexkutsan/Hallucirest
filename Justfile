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
  just --justfile mcp_servers/redis/Justfile --working-directory mcp_servers/redis install
  env CRYSTAL_CACHE_DIR=.crystal_cache just --justfile mcp_servers/redis/Justfile --working-directory mcp_servers/redis test

test-mongo:
  just --justfile mcp_servers/mongo/Justfile --working-directory mcp_servers/mongo install
  env CRYSTAL_CACHE_DIR=.crystal_cache just --justfile mcp_servers/mongo/Justfile --working-directory mcp_servers/mongo test

test-all: test-root test-redis test-mongo

lint: install
  ./bin/ameba src spec
  just --justfile mcp_servers/redis/Justfile --working-directory mcp_servers/redis lint
  just --justfile mcp_servers/mongo/Justfile --working-directory mcp_servers/mongo lint

format:
  crystal tool format src spec
  just --justfile mcp_servers/redis/Justfile --working-directory mcp_servers/redis format
  just --justfile mcp_servers/mongo/Justfile --working-directory mcp_servers/mongo format

format-check:
  crystal tool format --check src spec
  just --justfile mcp_servers/redis/Justfile --working-directory mcp_servers/redis format-check
  just --justfile mcp_servers/mongo/Justfile --working-directory mcp_servers/mongo format-check

secrets-scan:
  trufflehog git file://. --fail --no-update

clean:
  rm -rf .crystal
