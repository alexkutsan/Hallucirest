require "agent_kit"
require "./config"

module Hallucirest
  abstract class Runner
    abstract def run(prompt : String) : String
  end

  class AgentKitRunner < Runner
    def initialize(@config : AppConfig)
    end

    def run(prompt : String) : String
      agent_config = AgentKit::Config.new(
        openai_api_key: @config.openai_api_key,
        openai_api_host: @config.openai_api_host,
        openai_model: @config.openai_model,
        max_iterations: @config.max_iterations,
        timeout_seconds: @config.timeout_seconds,
        mcp_servers: @config.mcp_servers,
      )

      agent = AgentKit::Agent.new(agent_config, @config.system_prompt)

      begin
        agent.setup
        agent.run(prompt)
      ensure
        agent.cleanup
      end
    end
  end
end
