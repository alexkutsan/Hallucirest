require "./spec_helper"
require "../src/hallucirest/config"
require "file_utils"

module Hallucirest
  describe AppConfig do
    it "loads YAML config" do
      yaml = <<-YAML
      bind: 127.0.0.1
      port: 9999
      system_prompt: |
        Hello system
      agentkit:
        openai_api_key: k
        openai_api_host: https://api.cerebras.ai/
        openai_model: gpt-oss-120b
        max_iterations: 3
        timeout_seconds: 9
        mcp_servers:
          tools:
            type: http
            url: http://localhost:8000/mcp
      YAML

      cfg = AppConfig.from_yaml(yaml)
      cfg.bind_host.should eq("127.0.0.1")
      cfg.port.should eq(9999)
      cfg.system_prompt.should eq("Hello system\n")
      cfg.openai_api_key.should eq("k")
      cfg.openai_api_host.should eq("https://api.cerebras.ai/")
      cfg.openai_model.should eq("gpt-oss-120b")
      cfg.max_iterations.should eq(3)
      cfg.timeout_seconds.should eq(9)
      cfg.mcp_servers["tools"].url.should eq("http://localhost:8000/mcp")
    end

    it "expands ${VAR} and ${VAR:-default} in YAML" do
      env = {
        "OPENAI_API_KEY" => "k123",
      }

      yaml = <<-YAML
      bind: 0.0.0.0
      port: 8080
      agentkit:
        openai_api_key: ${OPENAI_API_KEY}
        openai_api_host: ${OPENAI_API_HOST:-https://api.cerebras.ai/}
        openai_model: ${OPENAI_MODEL:-gpt-oss-120b}
        max_iterations: ${MAX_ITERATIONS:-10}
        timeout_seconds: ${TIMEOUT_SECONDS:-120}
      YAML

      config = AppConfig.from_yaml(yaml, env)

      config.openai_api_key.should eq("k123")
      config.openai_api_host.should eq("https://api.cerebras.ai/")
      config.openai_model.should eq("gpt-oss-120b")
      config.max_iterations.should eq(10)
      config.timeout_seconds.should eq(120)
    end

    it "fails when api key is missing" do
      yaml = "bind: 0.0.0.0\nport: 8080\nagentkit: {}\n"
      expect_raises(ArgumentError, "OPENAI_API_KEY is required") do
        AppConfig.from_yaml(yaml)
      end
    end

    it "fails when port is not positive" do
      yaml = <<-YAML
      bind: 0.0.0.0
      port: 0
      agentkit:
        openai_api_key: k
      YAML

      expect_raises(ArgumentError, "PORT must be positive") do
        AppConfig.from_yaml(yaml)
      end
    end

    it "fails when max iterations is not positive" do
      yaml = <<-YAML
      bind: 0.0.0.0
      port: 8080
      agentkit:
        openai_api_key: k
        max_iterations: 0
      YAML

      expect_raises(ArgumentError, "MAX_ITERATIONS must be positive") do
        AppConfig.from_yaml(yaml)
      end
    end

    it "fails when timeout seconds is not positive" do
      yaml = <<-YAML
      bind: 0.0.0.0
      port: 8080
      agentkit:
        openai_api_key: k
        timeout_seconds: 0
      YAML

      expect_raises(ArgumentError, "TIMEOUT_SECONDS must be positive") do
        AppConfig.from_yaml(yaml)
      end
    end

    it "loads config from file" do
      base = Dir.tempdir
      dir = File.join(base, "hallucirest_spec_#{Random::Secure.hex(8)}")
      Dir.mkdir(dir)

      begin
        path = File.join(dir, "config.yml")
        yaml = <<-YAML
        bind: 127.0.0.1
        port: 9090
        agentkit:
          openai_api_key: k
        YAML

        File.write(path, yaml)

        cfg = AppConfig.from_file(path)
        cfg.bind_host.should eq("127.0.0.1")
        cfg.port.should eq(9090)
        cfg.openai_api_key.should eq("k")
      ensure
        FileUtils.rm_r(dir)
      end
    end

    it "(legacy) supports ENV-based config" do
      env = {
        "OPENAI_API_KEY" => "k",
      }

      cfg = AppConfig.from_env(env)
      cfg.openai_api_key.should eq("k")
    end

    it "(legacy) parses MCP_SERVERS_JSON from env" do
      env = {
        "OPENAI_API_KEY"   => "k",
        "MCP_SERVERS_JSON" => %({"tools":{"type":"http","url":"http://env"}}),
      }

      cfg = AppConfig.from_env(env)
      cfg.mcp_servers["tools"].url.should eq("http://env")
    end

    it "(legacy) fails on invalid MCP_SERVERS_JSON" do
      env = {
        "OPENAI_API_KEY"   => "k",
        "MCP_SERVERS_JSON" => "{not json}",
      }

      expect_raises(JSON::ParseException) do
        AppConfig.from_env(env)
      end
    end

    it "loads MCP servers from JSON file and merges with inline YAML" do
      base = Dir.tempdir
      dir = File.join(base, "hallucirest_spec_#{Random::Secure.hex(8)}")
      Dir.mkdir(dir)

      begin
        json_path = File.join(dir, "mcp.json")
        File.write(json_path, %({"mcpServers":{"from_json":{"type":"http","url":"http://json"},"override_me":{"type":"http","url":"http://old"}}}))

        yaml = <<-YAML
        bind: 127.0.0.1
        port: 8080
        agentkit:
          openai_api_key: k
          mcp_servers_json_path: #{json_path}
          mcp_servers:
            override_me:
              type: http
              url: http://new
        YAML

        cfg = AppConfig.from_yaml(yaml)
        cfg.mcp_servers["from_json"].url.should eq("http://json")
        cfg.mcp_servers["override_me"].url.should eq("http://new")
      ensure
        FileUtils.rm_r(dir)
      end
    end

    it "fails when MCP JSON file does not exist" do
      yaml = <<-YAML
      bind: 127.0.0.1
      port: 8080
      agentkit:
        openai_api_key: k
        mcp_servers_json_path: /definitely/does/not/exist.json
      YAML

      expect_raises(File::NotFoundError) do
        AppConfig.from_yaml(yaml)
      end
    end

    it "fails when MCP JSON file is invalid" do
      base = Dir.tempdir
      dir = File.join(base, "hallucirest_spec_#{Random::Secure.hex(8)}")
      Dir.mkdir(dir)

      begin
        json_path = File.join(dir, "mcp.json")
        File.write(json_path, "{not json}")

        yaml = <<-YAML
        bind: 127.0.0.1
        port: 8080
        agentkit:
          openai_api_key: k
          mcp_servers_json_path: #{json_path}
        YAML

        expect_raises(JSON::ParseException) do
          AppConfig.from_yaml(yaml)
        end
      ensure
        FileUtils.rm_r(dir)
      end
    end

    it "expands missing env placeholders to empty string" do
      env = {
        "OPENAI_API_KEY" => "k",
      }

      yaml = <<-YAML
      bind: 0.0.0.0
      port: 8080
      system_prompt: Hello${MISSING}World
      agentkit:
        openai_api_key: ${OPENAI_API_KEY}
      YAML

      cfg = AppConfig.from_yaml(yaml, env)
      cfg.system_prompt.should eq("HelloWorld")
    end

    it "expands multiple placeholders in YAML" do
      env = {
        "OPENAI_API_KEY" => "k",
        "A"              => "a",
      }

      yaml = <<-YAML
      bind: 0.0.0.0
      port: 8080
      system_prompt: ${A}-${B:-b}
      agentkit:
        openai_api_key: ${OPENAI_API_KEY}
      YAML

      cfg = AppConfig.from_yaml(yaml, env)
      cfg.system_prompt.should eq("a-b")
    end
  end
end
