require "option_parser"
require "log"
require "http/client"
require "openssl"
require "uri"
require "agent_kit"
require "./hallucirest/config"
require "./hallucirest/log"
require "./hallucirest/runner"
require "./hallucirest/server"

def verify_openai_access!(config : Hallucirest::AppConfig) : Nil
  uri = URI.parse(config.openai_api_host)
  uri = URI.parse("https://#{config.openai_api_host}") unless uri.scheme

  base_path = uri.path
  base_path = "" if base_path == "/"

  model_path = "#{base_path}/v1/models/#{URI.encode_path(config.openai_model)}"
  model_uri = uri.dup
  model_uri.path = model_path
  model_uri.query = nil

  headers = HTTP::Headers{
    "Authorization" => "Bearer #{config.openai_api_key}",
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
      raise ArgumentError.new("OpenAI API auth failed (HTTP #{status}). Check openai_api_key and permissions for host '#{config.openai_api_host}'.")
    when 404
      raise ArgumentError.new("OpenAI model '#{config.openai_model}' not found or not accessible on host '#{config.openai_api_host}' (HTTP 404).")
    else
      body = response.body
      body = body[0, 500] if body.size > 500
      raise ArgumentError.new("OpenAI API check failed for model '#{config.openai_model}' on host '#{config.openai_api_host}' (HTTP #{status}): #{body}")
    end
  rescue ex : Socket::Error
    raise ArgumentError.new("OpenAI API host '#{config.openai_api_host}' is unreachable: #{ex.message}")
  rescue ex : IO::TimeoutError
    raise ArgumentError.new("OpenAI API request to '#{config.openai_api_host}' timed out: #{ex.message}")
  rescue ex : OpenSSL::SSL::Error
    raise ArgumentError.new("OpenAI API TLS error for host '#{config.openai_api_host}': #{ex.message}")
  end
end

config_path = "config.yml"

OptionParser.parse do |parser|
  parser.on("--config=PATH", "Path to YAML config file (default: config.yml)") do |path|
    config_path = path
  end
end

severity = Log::Severity.parse?(ENV["LOG_LEVEL"]? || "info") || Log::Severity::Info

Log.setup(severity, Log::IOBackend.new)

Hallucirest::Log.info { "starting" }

config = Hallucirest::AppConfig.from_file(config_path)

begin
  verify_openai_access!(config)
rescue ex
  Hallucirest::Log.error { ex.message }
  exit(1)
end

runner = Hallucirest::AgentKitRunner.new(config)
server = Hallucirest::Server.build(config, runner)
server.start
