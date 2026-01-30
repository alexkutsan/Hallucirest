require "json"
require "http/client"
require "openssl"
require "uri"
require "yaml"
require "agent_kit"

module Hallucirest
  struct MCPServerConfig
    include JSON::Serializable
    include YAML::Serializable

    property type : String?
    property url : String?
    property headers : Hash(String, String)?
    property command : String?
    property args : Array(String)?
    property env : Hash(String, String)?
  end

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

    private def self.load_mcp_servers_from_file(path : String?) : Hash(String, MCPServerConfig)
      return {} of String => MCPServerConfig if path.nil? || path.empty?

      raw = File.read(path)
      parsed = MCPServersFile.from_json(raw)
      parsed.mcp_servers || ({} of String => MCPServerConfig)
    end

    struct AgentKitYaml
      include YAML::Serializable

      property openai_api_key : String?
      property openai_api_host : String?
      property openai_model : String?
      property max_iterations : Int32?
      property timeout_seconds : Int32?
      property mcp_servers_json_path : String?
      property mcp_servers : Hash(String, MCPServerConfig)?
    end

    private struct MCPServersFile
      include JSON::Serializable

      @[JSON::Field(key: "mcpServers")]
      property mcp_servers : Hash(String, MCPServerConfig)?
    end

    struct ConfigYaml
      include YAML::Serializable

      property bind : String?
      property port : Int32?
      property system_prompt : String?
      property agentkit : AgentKitYaml?
    end

    def self.from_yaml(yaml : String, env : Hash(String, String) = ENV.to_h) : self
      expanded = expand_env_placeholders(yaml, env)
      parsed = ConfigYaml.from_yaml(expanded)

      bind_host = parsed.bind || "0.0.0.0"
      port = parsed.port || 8080
      system_prompt = parsed.system_prompt

      agentkit = parsed.agentkit

      openai_api_key = agentkit.try(&.openai_api_key) || ""
      openai_api_host = agentkit.try(&.openai_api_host) || "https://api.openai.com"
      openai_model = agentkit.try(&.openai_model) || "gpt-4o"
      max_iterations = agentkit.try(&.max_iterations) || 10
      timeout_seconds = agentkit.try(&.timeout_seconds) || 120

      mcp_servers_from_file = load_mcp_servers_from_file(agentkit.try(&.mcp_servers_json_path))
      mcp_servers_inline = agentkit.try(&.mcp_servers) || ({} of String => MCPServerConfig)

      merged_mcp_servers = mcp_servers_from_file
      mcp_servers_inline.each do |name, cfg|
        merged_mcp_servers[name] = cfg
      end

      mcp_servers = merged_mcp_servers.transform_values do |s|
        AgentKit::MCPServerConfig.new(
          type: s.type,
          url: s.url,
          headers: s.headers,
          command: s.command,
          args: s.args,
          env: s.env,
        )
      end

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

    def self.from_file(path : String, env : Hash(String, String) = ENV.to_h) : self
      from_yaml(File.read(path), env)
    end

    def validate! : Nil
      raise ArgumentError.new("OPENAI_API_KEY is required") if @openai_api_key.empty?
      raise ArgumentError.new("PORT must be positive") if @port <= 0
      raise ArgumentError.new("MAX_ITERATIONS must be positive") if @max_iterations <= 0
      raise ArgumentError.new("TIMEOUT_SECONDS must be positive") if @timeout_seconds <= 0
    end

    def verify_openai_access!(env : Hash(String, String) = ENV.to_h) : Nil
      uri = URI.parse(@openai_api_host)
      uri = URI.parse("https://#{@openai_api_host}") unless uri.scheme

      base_path = uri.path
      base_path = "" if base_path == "/"

      model_path = "#{base_path}/v1/models/#{URI.encode_path(@openai_model)}"
      model_uri = uri.dup
      model_uri.path = model_path
      model_uri.query = nil

      headers = HTTP::Headers{
        "Authorization" => "Bearer #{@openai_api_key}",
      }

      begin
        client = HTTP::Client.new(model_uri)
        client.connect_timeout = 5.seconds
        client.read_timeout = 10.seconds

        begin
          response = client.get(model_uri.request_target, headers: headers)
        ensure
          client.close
        end
        status = response.status_code

        case status
        when 200
          return
        when 401, 403
          raise ArgumentError.new("OpenAI API auth failed (HTTP #{status}). Check openai_api_key and permissions for host '#{@openai_api_host}'.")
        when 404
          raise ArgumentError.new("OpenAI model '#{@openai_model}' not found or not accessible on host '#{@openai_api_host}' (HTTP 404).")
        else
          body = response.body
          body = body[0, 500] if body.size > 500
          raise ArgumentError.new("OpenAI API check failed for model '#{@openai_model}' on host '#{@openai_api_host}' (HTTP #{status}): #{body}")
        end
      rescue ex : Socket::Error
        raise ArgumentError.new("OpenAI API host '#{@openai_api_host}' is unreachable: #{ex.message}")
      rescue ex : IO::TimeoutError
        raise ArgumentError.new("OpenAI API request to '#{@openai_api_host}' timed out: #{ex.message}")
      rescue ex : OpenSSL::SSL::Error
        raise ArgumentError.new("OpenAI API TLS error for host '#{@openai_api_host}': #{ex.message}")
      end
    end

    private def self.parse_mcp_servers(raw : String?) : Hash(String, AgentKit::MCPServerConfig)
      return {} of String => AgentKit::MCPServerConfig if raw.nil? || raw.empty?

      parsed = Hash(String, MCPServerConfig).from_json(raw)
      parsed.transform_values do |s|
        AgentKit::MCPServerConfig.new(
          type: s.type,
          url: s.url,
          headers: s.headers,
          command: s.command,
          args: s.args,
          env: s.env,
        )
      end
    end
  end
end
