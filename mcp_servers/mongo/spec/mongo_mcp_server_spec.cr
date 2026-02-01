require "spec"
require "http/client"
require "json"

require "./mcp_stdio_helper_spec"

describe "mongo_mcp_server" do
  it "supports initialize, tools/list, and insert/find/delete_all" do
    unless ENV["RUN_MONGO_MCP_SPEC"]? == "1"
      pending!("Set RUN_MONGO_MCP_SPEC=1 to run (requires a running MongoDB)")
    end

    env = {
      "MONGO_URL" => (ENV["MONGO_URL"]? || "mongodb://127.0.0.1:27017"),
    }

    client = MCPStdioClient.new("shards", ["run", "mongo_mcp_server"], env: env)

    begin
      init_params = JSON.parse(%({"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"spec","version":"0"}}))
      init = client.request(1, "initialize", init_params)
      init["serverInfo"]["name"].as_s.should eq("mongo_mcp_server")

      tools = client.request(2, "tools/list")
      names = tools["tools"].as_a.map(&.["name"].as_s)
      names.includes?("mongo_find").should be_true
      names.includes?("mongo_insert_one").should be_true
      names.includes?("mongo_delete_all").should be_true

      client.request(3, "tools/call", JSON.parse(%({"name":"mongo_insert_one","arguments":{"db":"d","collection":"c","document":{"x":1}}})))

      find = client.request(4, "tools/call", JSON.parse(%({"name":"mongo_find","arguments":{"db":"d","collection":"c"}})))
      docs_json = find["content"].as_a[0].as_s
      docs = JSON.parse(docs_json).as_a
      docs.size.should eq(1)
      docs[0]["x"].as_i.should eq(1)

      del = client.request(5, "tools/call", JSON.parse(%({"name":"mongo_delete_all","arguments":{"db":"d","collection":"c"}})))
      del["content"].as_a[0].as_s.should eq("1")

      find2 = client.request(6, "tools/call", JSON.parse(%({"name":"mongo_find","arguments":{"db":"d","collection":"c"}})))
      docs2 = JSON.parse(find2["content"].as_a[0].as_s).as_a
      docs2.size.should eq(0)
    ensure
      client.close
    end
  end
end
