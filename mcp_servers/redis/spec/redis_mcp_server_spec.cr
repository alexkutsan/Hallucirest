require "spec"
require "http/client"
require "json"

require "../src/redis_mcp_server"

class FakeRedisClient
  include RedisMcpServer::RedisClient

  @kv = {} of String => String
  @hashes = {} of String => Hash(String, String)

  def get(key : String) : String?
    @kv[key]?
  end

  def set(key : String, value : String) : String
    @kv[key] = value
    "OK"
  end

  def del(key : String) : Int64
    existed = @kv.delete(key)
    existed ? 1_i64 : 0_i64
  end

  def hset(key : String, field : String, value : String) : Int64
    h = @hashes[key]?
    unless h
      h = {} of String => String
      @hashes[key] = h
    end
    existed = h.has_key?(field)
    h[field] = value
    existed ? 0_i64 : 1_i64
  end

  def hdel(key : String, field : String) : Int64
    h = @hashes[key]?
    return 0_i64 unless h

    existed = h.delete(field)
    existed ? 1_i64 : 0_i64
  end

  def hgetall(key : String) : Hash(String, String)
    (@hashes[key]? || ({} of String => String)).dup
  end
end

class RedisMcpTestHarness
  getter server : RedisMcpServer::Server
  getter client : HTTP::Client
  getter session_id : String

  def initialize
    @server = RedisMcpServer::Server.new("127.0.0.1", 0, FakeRedisClient.new)

    spawn do
      @server.start
    end

    until port = @server.bound_port
      sleep 10.milliseconds
    end

    @client = HTTP::Client.new("127.0.0.1", port)
    @session_id = initialize_session
  end

  def close : Nil
    @server.stop
  end

  def mcp_headers : HTTP::Headers
    HTTP::Headers{
      "Content-Type"   => "application/json",
      "Accept"         => "application/json, text/event-stream",
      "Mcp-Session-Id" => @session_id,
    }
  end

  private def initialize_session : String
    init_params = JSON.parse(%({"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"spec","version":"0"}}))
    init_body = {"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => init_params}.to_json
    init_resp = @client.post("/mcp", headers: HTTP::Headers{"Content-Type" => "application/json", "Accept" => "application/json, text/event-stream"}, body: init_body)
    init_resp.status_code.should eq(200)
    init_resp.headers["Mcp-Session-Id"]? || raise "Missing Mcp-Session-Id"
  end
end

describe "redis_mcp_server" do
  it "responds to /health" do
    h = RedisMcpTestHarness.new
    begin
      resp = h.client.get("/health")
      resp.status_code.should eq(200)
      JSON.parse(resp.body)["ok"].as_bool.should be_true
    ensure
      h.close
    end
  end

  it "lists tools" do
    h = RedisMcpTestHarness.new
    begin
      tools_body = {"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}.to_json
      tools_resp = h.client.post("/mcp", headers: h.mcp_headers, body: tools_body)
      tools = JSON.parse(tools_resp.body)["result"]
      names = tools["tools"].as_a.map(&.["name"].as_s)

      names.includes?("redis_get").should be_true
      names.includes?("redis_set").should be_true
      names.includes?("redis_del").should be_true
      names.includes?("redis_hset").should be_true
      names.includes?("redis_hdel").should be_true
      names.includes?("redis_hgetall").should be_true
    ensure
      h.close
    end
  end

  it "supports set/get/del" do
    h = RedisMcpTestHarness.new
    begin
      set_body = {"jsonrpc" => "2.0", "id" => 3, "method" => "tools/call", "params" => {"name" => "redis_set", "arguments" => {"key" => "k", "value" => "v"}}}.to_json
      h.client.post("/mcp", headers: h.mcp_headers, body: set_body)

      get_body = {"jsonrpc" => "2.0", "id" => 4, "method" => "tools/call", "params" => {"name" => "redis_get", "arguments" => {"key" => "k"}}}.to_json
      get_res = JSON.parse(h.client.post("/mcp", headers: h.mcp_headers, body: get_body).body)["result"]
      get_res["content"].as_a[0]["text"].as_s.should eq("v")
      get_res["isError"].as_bool.should be_false

      del_body = {"jsonrpc" => "2.0", "id" => 5, "method" => "tools/call", "params" => {"name" => "redis_del", "arguments" => {"key" => "k"}}}.to_json
      del_res = JSON.parse(h.client.post("/mcp", headers: h.mcp_headers, body: del_body).body)["result"]
      del_res["content"].as_a[0]["text"].as_s.should eq("1")

      get2_res = JSON.parse(h.client.post("/mcp", headers: h.mcp_headers, body: get_body).body)["result"]
      get2_res["isError"].as_bool.should be_true
    ensure
      h.close
    end
  end

  it "supports hset/hgetall/hdel" do
    h = RedisMcpTestHarness.new
    begin
      hash_key = "hash:spec"

      hgetall_body = {"jsonrpc" => "2.0", "id" => 6, "method" => "tools/call", "params" => {"name" => "redis_hgetall", "arguments" => {"key" => hash_key}}}.to_json
      hgetall_empty = JSON.parse(h.client.post("/mcp", headers: h.mcp_headers, body: hgetall_body).body)["result"]
      JSON.parse(hgetall_empty["content"].as_a[0]["text"].as_s).as_h.should eq({} of String => JSON::Any)

      hset_body = {"jsonrpc" => "2.0", "id" => 7, "method" => "tools/call", "params" => {"name" => "redis_hset", "arguments" => {"key" => hash_key, "field" => "f", "value" => "v"}}}.to_json
      hset_res = JSON.parse(h.client.post("/mcp", headers: h.mcp_headers, body: hset_body).body)["result"]
      hset_res["isError"].as_bool.should be_false
      hset_res["content"].as_a[0]["text"].as_s.should eq("1")

      hgetall_after_set = JSON.parse(h.client.post("/mcp", headers: h.mcp_headers, body: hgetall_body).body)["result"]
      hgetall_json = JSON.parse(hgetall_after_set["content"].as_a[0]["text"].as_s)
      hgetall_json["f"].as_s.should eq("v")

      hdel_body = {"jsonrpc" => "2.0", "id" => 8, "method" => "tools/call", "params" => {"name" => "redis_hdel", "arguments" => {"key" => hash_key, "field" => "f"}}}.to_json
      hdel_res = JSON.parse(h.client.post("/mcp", headers: h.mcp_headers, body: hdel_body).body)["result"]
      hdel_res["isError"].as_bool.should be_false
      hdel_res["content"].as_a[0]["text"].as_s.should eq("1")

      hgetall_after_del = JSON.parse(h.client.post("/mcp", headers: h.mcp_headers, body: hgetall_body).body)["result"]
      JSON.parse(hgetall_after_del["content"].as_a[0]["text"].as_s).as_h.should eq({} of String => JSON::Any)
    ensure
      h.close
    end
  end
end
