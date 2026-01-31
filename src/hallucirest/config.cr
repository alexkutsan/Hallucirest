require "json"
require "yaml"
require "agent_kit"

module Hallucirest
  struct AppConfig
    getter bind_host : String
    getter port : Int32
    getter system_prompt : String?

    getter openai_api_key : String
    getter openai_api_host : String
    getter openai_model : String
    getter max_iterations : Int32
    getter timeout_seconds : Int32
    getter mcp_servers : Hash(String, AgentKit::MCPServerConfig)

    def initialize(
      @bind_host : String,
      @port : Int32,
      @openai_api_key : String,
      @openai_api_host : String,
      @openai_model : String,
      @max_iterations : Int32,
      @timeout_seconds : Int32,
      @mcp_servers : Hash(String, AgentKit::MCPServerConfig),
      @system_prompt : String? = nil,
    )
    end

    def self.from_env(env : Hash(String, String) = ENV.to_h) : self
      bind_host = env["BIND"]? || "0.0.0.0"
      port = (env["PORT"]? || "8080").to_i

      openai_api_key = env["OPENAI_API_KEY"]? || ""
      openai_api_host = env["OPENAI_API_HOST"]? || "https://api.openai.com"
      openai_model = env["OPENAI_MODEL"]? || "gpt-4o"
      max_iterations = (env["MAX_ITERATIONS"]? || "10").to_i
      timeout_seconds = (env["TIMEOUT_SECONDS"]? || "120").to_i
      system_prompt = env["SYSTEM_PROMPT"]?

      mcp_servers = parse_mcp_servers(env["MCP_SERVERS_JSON"]?)

      config = new(
        bind_host: bind_host,
        port: port,
        openai_api_key: openai_api_key,
        openai_api_host: openai_api_host,
        openai_model: openai_model,
        max_iterations: max_iterations,
        timeout_seconds: timeout_seconds,
        mcp_servers: mcp_servers,
        system_prompt: system_prompt,
      )

      config.validate!
      config
    end

    private def self.expand_env_placeholders(input : String, env : Hash(String, String)) : String
      input.gsub(/\$\{([A-Z0-9_]+)(:-([^}]*))?\}/) do |_|
        var = $1
        default = $3?
        env[var]? || default || ""
      end
    end

    private def self.load_mcp_servers_from_file(path : String?) : Hash(String, AgentKit::MCPServerConfig)
      return {} of String => AgentKit::MCPServerConfig if path.nil? || path.empty?

      raw = File.read(path)
      parsed = MCPServersFile.from_json(raw)
      parsed.mcp_servers || ({} of String => AgentKit::MCPServerConfig)
    end

    private struct MCPServersFile
      include JSON::Serializable

      @[JSON::Field(key: "mcpServers")]
      property mcp_servers : Hash(String, AgentKit::MCPServerConfig)?
    end

    private struct ConfigYaml
      include YAML::Serializable

      property bind : String?
      property port : Int32?
      property system_prompt : String?
      property agentkit : AgentKit::Config?
    end

    def self.from_yaml(yaml : String, env : Hash(String, String) = ENV.to_h) : self
      expanded = expand_env_placeholders(yaml, env)
      parsed = ConfigYaml.from_yaml(expanded)

      bind_host = parsed.bind || "0.0.0.0"
      port = parsed.port || 8080
      system_prompt = parsed.system_prompt

      agentkit = parsed.agentkit || AgentKit::Config.new

      mcp_servers_from_file = load_mcp_servers_from_file(agentkit.mcp_servers_json_path)
      mcp_servers = mcp_servers_from_file
      agentkit.mcp_servers.each do |name, cfg|
        mcp_servers[name] = cfg
      end

      config = new(
        bind_host: bind_host,
        port: port,
        openai_api_key: agentkit.openai_api_key,
        openai_api_host: agentkit.openai_api_host,
        openai_model: agentkit.openai_model,
        max_iterations: agentkit.max_iterations,
        timeout_seconds: agentkit.timeout_seconds,
        mcp_servers: mcp_servers,
        system_prompt: system_prompt,
      )

      config.validate!
      config
    end

    def self.from_file(path : String, env : Hash(String, String) = ENV.to_h) : self
      from_yaml(File.read(path), env)
    end

    def validate! : Nil
      raise ArgumentError.new("OPENAI_API_KEY is required") if @openai_api_key.empty?
      raise ArgumentError.new("PORT must be positive") if @port <= 0
      raise ArgumentError.new("MAX_ITERATIONS must be positive") if @max_iterations <= 0
      raise ArgumentError.new("TIMEOUT_SECONDS must be positive") if @timeout_seconds <= 0
    end


    private def self.parse_mcp_servers(raw : String?) : Hash(String, AgentKit::MCPServerConfig)
      return {} of String => AgentKit::MCPServerConfig if raw.nil? || raw.empty?

      Hash(String, AgentKit::MCPServerConfig).from_json(raw)
    end
  end
end
