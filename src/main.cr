require "option_parser"
require "log"
require "agent_kit"
require "./hallucirest/config"
require "./hallucirest/log"
require "./hallucirest/runner"
require "./hallucirest/server"

config_path = "config.yml"

OptionParser.parse do |parser|
  parser.on("--config=PATH", "Path to YAML config file (default: config.yml)") do |path|
    config_path = path
  end
end

level = (ENV["LOG_LEVEL"]? || "info").downcase
severity = case level
           when "trace" then Log::Severity::Trace
           when "debug" then Log::Severity::Debug
           when "info"  then Log::Severity::Info
           when "warn"  then Log::Severity::Warn
           when "error" then Log::Severity::Error
           when "fatal" then Log::Severity::Fatal
           else
             Log::Severity::Info
           end

Log.setup(severity, Log::IOBackend.new)

Hallucirest::Log.info { "starting" }

config = Hallucirest::AppConfig.from_file(config_path)

begin
  config.verify_openai_access!
rescue ex
  Hallucirest::Log.error { ex.message }
  exit(1)
end

runner = Hallucirest::AgentKitRunner.new(config)
server = Hallucirest::Server.build(config, runner)
server.start