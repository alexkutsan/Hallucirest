require "json"

class MCPStdioClient
  def initialize(@command : String, @args : Array(String), @chdir : String? = nil, @env : Hash(String, String)? = nil)
    @process = Process.new(
      @command,
      @args,
      chdir: @chdir,
      env: @env,
      input: Process::Redirect::Pipe,
      output: Process::Redirect::Pipe,
      error: Process::Redirect::Pipe,
    )

    @stdin = @process.input.as(IO)
    @stdout = @process.output.as(IO)
    @stderr = @process.error.as(IO)

    spawn do
      begin
        @stderr.each_line { |l| l }
      rescue
      end
    end
  end

  def close
    begin
      @stdin.close
    rescue
    end

    begin
      @stdout.close
    rescue
    end

    begin
      @stderr.close
    rescue
    end

    begin
      @process.terminate
    rescue
    end

    begin
      @process.wait
    rescue
    end
  end

  def request(id : Int32, method : String, params : JSON::Any? = nil, timeout : Time::Span = 10.seconds) : JSON::Any
    msg = JSON.build do |j|
      j.object do
        j.field "jsonrpc", "2.0"
        j.field "id", id
        j.field "method", method
        j.field "params", params if params
      end
    end

    @stdin.puts(msg)
    @stdin.flush

    read_response(id, timeout)
  end

  private def read_response(expected_id : Int32, timeout : Time::Span) : JSON::Any
    deadline = Time.instant + timeout

    loop do
      remaining = deadline - Time.instant
      raise "MCP server timeout" if remaining <= 0.seconds

      line = ""
      ch = Channel(String).new(1)
      spawn do
        begin
          ch.send(@stdout.gets || "")
        rescue
          ch.send("")
        end
      end

      line = select
      when v = ch.receive
        v
      when timeout(remaining)
        ""
      end

      next if line.empty?

      json = JSON.parse(line)
      id = json["id"]?.try(&.as_i?)
      next unless id == expected_id

      if err = json["error"]?
        raise "MCP error: #{err.to_json}"
      end

      return json["result"]
    end
  end
end
