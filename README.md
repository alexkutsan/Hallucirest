# Hallucirest

An HTTP server whose runtime is controlled by an LLM.

## What it does

- **[Prompt-in]** An incoming HTTP request becomes a prompt.
- **[Agent loop]** Runs an agent loop via `AgentKit`.
- **[Tools]** Can connect to MCP servers and expose their tools to the agent.
- **[Response-out]** The final LLM output becomes the HTTP response.

## How it is supposed to work (conceptually)

1. A client sends an HTTP request.
2. The server extracts text from the request (e.g., from the request body or a query parameter) and forms the `user prompt`.
3. The server creates/initializes an agent:
   - the system prompt is taken from server startup arguments;
   - the list of MCP servers is taken from the startup configuration.
4. The agent runs an Agent Loop, calling tools via MCP when needed.
5. The final text (and/or a structured result) is returned as the HTTP response.

## Dependencies

- Crystal `>= 1.19.0`
- Shards
- `AgentKit` (added as a shard dependency)

## Quick start (Docker Compose)

The easiest way to try Hallucirest is with Docker Compose. The example includes Redis and MongoDB with their MCP servers.

**Prerequisites:**
- Docker and Docker Compose
- OpenAI-compatible API key (e.g., OpenAI, Cerebras)

**1. Set your API key:**

```bash
export OPENAI_API_KEY=your_api_key_here
```

**2. Start the services:**

```bash
docker compose up -d
```

This will start:
- `redis` — Redis database
- `mongo` — MongoDB database
- `redis_mcp_server` — HTTP MCP server for Redis tools
- `hallucirest` — the main server (available at http://localhost:8085), includes MongoDB MCP server (stdio)

**3. Try it out:**

Open http://localhost:8085 in your browser to see the "Place Reviews" demo site.

### Getting a free Cerebras API key

The example uses [Cerebras](https://cerebras.ai/) as the LLM provider because:
- Free tier available (no credit card required)
- Very fast inference (~2000 tokens/sec)
- OpenAI-compatible API

To get a key:
1. Sign up at https://cloud.cerebras.ai/
2. Go to "API Keys" and create a new key
3. Set it as `OPENAI_API_KEY` environment variable

### Configuration

The Docker example uses `docker/config.yml` which configures:
- System prompt for the "Place Reviews" website
- LLM provider settings (default: Cerebras, can be changed to OpenAI or other compatible APIs)
- MCP servers: Redis (HTTP) and MongoDB (stdio)

To customize, edit `docker/config.yml` or create your own config file.

---

## Quick start (dev)

Install dependencies:

```bash
shards install
```

Run (current state):

```bash
crystal run src/main.cr
```

Then call the server:

```bash
curl -sS http://127.0.0.1:8080/health
```

```bash
curl -sS \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Hello"}' \
  http://127.0.0.1:8080/prompt
```

Build a binary:

```bash
shards build
```

After building, the binary will be placed in `bin/` (name depends on `targets` in `shard.yml`).

## Configuration

Environment variables:

- **[BIND]** Bind address. Default: `0.0.0.0`
- **[PORT]** Port. Default: `8080`
- **[SYSTEM_PROMPT]** Optional system prompt.
- **[OPENAI_API_KEY]** Required API key.
- **[OPENAI_API_HOST]** Base URL. Default: `https://api.openai.com`
- **[OPENAI_MODEL]** Model name. Default: `gpt-4o`
- **[MAX_ITERATIONS]** Agent loop max iterations. Default: `10`
- **[TIMEOUT_SECONDS]** LLM request timeout. Default: `120`
- **[MCP_SERVERS_JSON]** Optional JSON map of MCP server configs.

Example `MCP_SERVERS_JSON`:

```json
{
  "tools": {
    "type": "http",
    "url": "http://localhost:8000/mcp"
  }
}
```

## Usage

Endpoints:

- **[GET /health]** returns `{"ok": true}`.
- **[POST /prompt]** accepts either:
  - `application/json` with `{"prompt": "..."}`
  - `text/plain` with the prompt as the request body

Response format:

- `200`: `{"result": "..."}`
- `4xx/5xx`: `{"error": "..."}`

## Security

An LLM agent with access to tools (via MCP) can potentially perform dangerous actions.

Recommendations:

- **[Isolation]** run the service in an isolated environment (container/VM) with minimal privileges.
- **[Tool audit]** enable only the MCP servers/tools you truly need.
- **[Limits]** enforce time/token/request-size limits and rate limiting.
- **[Logs]** log prompts and agent actions (avoid logging secrets).

## License

MIT
