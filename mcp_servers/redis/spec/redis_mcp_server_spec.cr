require "spec"
require "http/client"
require "json"

describe "redis_mcp_server" do
  it "supports initialize, tools/list, and set/get/del" do
    unless ENV["RUN_REDIS_MCP_SPEC"]? == "1"
      pending!("Set RUN_REDIS_MCP_SPEC=1 to run (requires a running Redis)")
    end

    port = 18_000 + Random.rand(2_000)
    env = {
      "REDIS_MCP_BIND" => "127.0.0.1",
      "REDIS_MCP_PORT" => port.to_s,
      "REDIS_URL"      => (ENV["REDIS_URL"]? || "redis://127.0.0.1:6379"),
    }

    process = Process.new(
      "shards",
      ["run", "redis_mcp_server"],
      env: env,
      input: Process::Redirect::Close,
      output: Process::Redirect::Inherit,
      error: Process::Redirect::Inherit,
    )

    begin
      client = HTTP::Client.new("127.0.0.1", port)

      ready = false
      250.times do
        begin
          r = client.get("/health")
          if r.status_code == 200
            ready = true
            break
          end
        rescue
        end
        sleep 20.milliseconds
      end

      ready.should be_true

      session = nil

      init_params = JSON.parse(%({"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"spec","version":"0"}}))
      init_body = {"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => init_params}.to_json
      init_resp = client.post("/mcp", headers: HTTP::Headers{"Content-Type" => "application/json", "Accept" => "application/json, text/event-stream"}, body: init_body)
      init_resp.status_code.should eq(200)
      session = init_resp.headers["Mcp-Session-Id"]?
      session.should_not be_nil

      init_json = JSON.parse(init_resp.body)
      init_json["result"]["serverInfo"]["name"].as_s.should eq("redis_mcp_server")

      headers = HTTP::Headers{"Content-Type" => "application/json", "Accept" => "application/json, text/event-stream", "Mcp-Session-Id" => session.not_nil!}

      tools_body = {"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}.to_json
      tools_resp = client.post("/mcp", headers: headers, body: tools_body)
      tools = JSON.parse(tools_resp.body)["result"]
      names = tools["tools"].as_a.map(&.["name"].as_s)
      names.includes?("redis_get").should be_true
      names.includes?("redis_set").should be_true
      names.includes?("redis_del").should be_true

      set_body = {"jsonrpc" => "2.0", "id" => 3, "method" => "tools/call", "params" => {"name" => "redis_set", "arguments" => {"key" => "k", "value" => "v"}}}.to_json
      client.post("/mcp", headers: headers, body: set_body)

      get_body = {"jsonrpc" => "2.0", "id" => 4, "method" => "tools/call", "params" => {"name" => "redis_get", "arguments" => {"key" => "k"}}}.to_json
      get_res = JSON.parse(client.post("/mcp", headers: headers, body: get_body).body)["result"]
      get_res["content"].as_a[0]["text"].as_s.should eq("v")
      get_res["isError"].as_bool.should be_false

      del_body = {"jsonrpc" => "2.0", "id" => 5, "method" => "tools/call", "params" => {"name" => "redis_del", "arguments" => {"key" => "k"}}}.to_json
      del_res = JSON.parse(client.post("/mcp", headers: headers, body: del_body).body)["result"]
      del_res["content"].as_a[0]["text"].as_s.should eq("1")

      get2_res = JSON.parse(client.post("/mcp", headers: headers, body: get_body).body)["result"]
      get2_res["isError"].as_bool.should be_true
    ensure
      begin
        process.terminate
      rescue
      end
      begin
        process.wait
      rescue
      end
    end
  end
end
