# Mattermost WebSocket Mention Trigger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `mattermost` trigger that runs an agent task when the bot is @-mentioned in an allowlisted channel, replying in the same thread.

**Architecture:** A Daemon-managed listener thread holds a stdlib WebSocket to the Mattermost Bot API, filters `posted` mention events, and writes each one as a YAML work-item into an inbox dir. A file-poll consumer runner (`Runner::Mattermost < Runner::File`) processes them sequentially through the backend. The agent replies by writing a message YAML routed back into the thread via the existing Messenger + Mattermost transport (extended for `channel_id` + `root_id`).

**Tech Stack:** Ruby stdlib only — `socket`, `openssl`, `securerandom`, `digest`, `base64`, `net/http`, `json`, `uri`, `yaml`, `fileutils`. Minitest for tests.

## Global Constraints

- **Stdlib only** — no runtime gem dependencies may be added (`minitest`/`rake` are dev-only). Copy verbatim from AGENTS.md.
- Every Ruby file starts with `# frozen_string_literal: true`.
- Tests are Minitest (`test/test_*.rb`), no spec DSL. Net::HTTP is stubbed via `stub_net_http` + `FakeHttp` from `test/test_helper.rb` (Minitest 6 has no mock).
- New lib files must be added to `lib/agent_daemon.rb` with `require_relative` in the same task that creates them, or their tests cannot load the class.
- Path resolution: `message_dir`/`output_dir` and file-style trigger dirs resolve relative to `project_path`; `prompt_template` relative to the config file's directory.
- Config validation collects ALL errors and raises one `ConfigError` (fail-fast, all problems at once) — preserve this.
- Run the full suite with `rake test`; a single file with `ruby -Ilib -Itest test/test_<name>.rb`.
- This is a published gem: bump `lib/agent_daemon/version.rb` and update `CHANGELOG.md` (final task).
- End every commit message with the trailer:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

## File Structure

| File | Responsibility | Task |
|------|----------------|------|
| `lib/agent_daemon/mattermost/web_socket.rb` | Stdlib RFC 6455 client (handshake, framing, ping/pong, shutdown-aware reads) | 1 |
| `lib/agent_daemon/transport/mattermost.rb` (modify) | Add `channel_id` (verbatim) + `root_id` (threading) to `deliver` | 2 |
| `lib/agent_daemon/config.rb` (modify) | `mattermost` trigger defaults, dir resolution, validation | 3 |
| `lib/agent_daemon/runner/mattermost.rb` | Consumer: file-poll runner that maps work-item YAML fields to prompt vars | 4 |
| `lib/agent_daemon/mattermost/listener.rb` | Listener thread: bot-id resolution, event filtering, work-item writing, reconnect loop | 5 |
| `lib/agent_daemon/daemon.rb` (modify) | Expand a `mattermost` runner into a `runner:<name>` + `listener:<name>` thread pair | 6 |
| `lib/agent_daemon.rb` (modify) | `require_relative` the three new files | 1, 4, 5 |
| `docs/architecture.md`, `examples/config.yml`, `examples/prompts/mention.txt`, `CHANGELOG.md`, `lib/agent_daemon/version.rb` (modify) | Docs, example, release | 7 |

---

### Task 1: WebSocket client (`Mattermost::WebSocket`)

**Files:**
- Create: `lib/agent_daemon/mattermost/web_socket.rb`
- Modify: `lib/agent_daemon.rb` (add `require_relative "agent_daemon/mattermost/web_socket"` after the transport requires)
- Test: `test/test_mattermost_web_socket.rb`

**Interfaces:**
- Produces:
  - `AgentDaemon::Mattermost::WebSocket::GUID` → `"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"`
  - `WebSocket.encode_client_frame(opcode_int, payload_str)` → masked client frame `String` (BINARY, FIN set)
  - `WebSocket.decode_server_frame(reader)` → `{ opcode: Integer, payload: String }`; `reader` responds to `read(n)`
  - `WebSocket.apply_mask(data_str, key_str)` → `String`
  - `WebSocket.new(url_str, shutdown_flag, read_timeout: 1)` ; instance methods `connect → self`, `send_text(str)`, `each_message { |text| }`, `close`
  - `shutdown_flag` responds to `value` (truthy ⇒ stop)

- [ ] **Step 1: Write the failing tests**

Create `test/test_mattermost_web_socket.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"
require "socket"
require "stringio"
require "digest"
require "base64"

class TestMattermostWebSocket < Minitest::Test
  WS = AgentDaemon::Mattermost::WebSocket

  class AlwaysOn
    def value = false
  end

  def test_encode_client_frame_sets_fin_mask_and_round_trips
    frame = WS.encode_client_frame(0x1, "hello")
    bytes = frame.bytes
    assert_equal 0x81, bytes[0]              # FIN + text opcode
    assert_equal (0x80 | 5), bytes[1]        # MASK bit + payload length 5
    mask = frame.byteslice(2, 4)
    masked = frame.byteslice(6, 5)
    assert_equal "hello", WS.apply_mask(masked, mask)
  end

  def test_decode_server_frame_reads_unmasked_text
    raw = [0x81, 5].pack("C2") + "world"
    frame = WS.decode_server_frame(StringIO.new(raw))
    assert_equal 0x1, frame[:opcode]
    assert_equal "world", frame[:payload]
  end

  def test_decode_server_frame_handles_extended_16bit_length
    payload = "a" * 200
    raw = [0x81, 126].pack("C2") + [200].pack("n") + payload
    frame = WS.decode_server_frame(StringIO.new(raw))
    assert_equal 200, frame[:payload].bytesize
  end

  def test_connect_completes_handshake_and_streams_text_until_close
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]

    srv = Thread.new do
      client = server.accept
      key = nil
      while (line = client.gets) && line != "\r\n"
        key = line.split(":", 2)[1].strip if line.downcase.start_with?("sec-websocket-key:")
      end
      accept = Base64.strict_encode64(Digest::SHA1.digest(key + WS::GUID))
      client.write("HTTP/1.1 101 Switching Protocols\r\n")
      client.write("Upgrade: websocket\r\nConnection: Upgrade\r\n")
      client.write("Sec-WebSocket-Accept: #{accept}\r\n\r\n")
      client.write([0x81, 2].pack("C2") + "hi")   # text frame, unmasked
      client.write([0x88, 0].pack("C2"))           # close frame
      sleep 0.2
      client.close rescue nil
    end

    ws = WS.new("ws://127.0.0.1:#{port}/ws", AlwaysOn.new)
    ws.connect
    messages = []
    ws.each_message { |m| messages << m }
    assert_equal ["hi"], messages
  ensure
    ws&.close
    server&.close
    srv&.join(1)
  end

  def test_connect_raises_on_non_101_status
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    srv = Thread.new do
      client = server.accept
      client.gets until client.gets == "\r\n" rescue nil
      client.write("HTTP/1.1 401 Unauthorized\r\n\r\n")
      client.close rescue nil
    end

    ws = WS.new("ws://127.0.0.1:#{port}/ws", AlwaysOn.new)
    err = assert_raises(RuntimeError) { ws.connect }
    assert_includes err.message, "handshake"
  ensure
    server&.close
    srv&.join(1)
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_mattermost_web_socket.rb`
Expected: FAIL — `uninitialized constant AgentDaemon::Mattermost` (class not defined yet).

- [ ] **Step 3: Implement the WebSocket client**

Create `lib/agent_daemon/mattermost/web_socket.rb`:

```ruby
# frozen_string_literal: true

require "socket"
require "openssl"
require "securerandom"
require "digest"
require "base64"
require "uri"

module AgentDaemon
  module Mattermost
    # Minimal stdlib RFC 6455 client. Connects over TCP (ws) or TLS (wss),
    # performs the upgrade handshake, and exchanges text frames. Reads are
    # shutdown-aware: each read blocks on IO.select for at most read_timeout
    # seconds so the loop can poll the shutdown flag. Client->server frames are
    # masked (spec requirement); server->client frames are not.
    class WebSocket
      GUID     = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
      OP_TEXT  = 0x1
      OP_CLOSE = 0x8
      OP_PING  = 0x9
      OP_PONG  = 0xA

      def initialize(url, shutdown_flag, read_timeout: 1)
        @uri = URI(url)
        @shutdown_flag = shutdown_flag
        @read_timeout = read_timeout
        @port = @uri.port || (@uri.scheme == "wss" ? 443 : 80)
      end

      def connect
        @socket = open_socket
        perform_handshake
        self
      end

      def send_text(payload)
        @socket.write(self.class.encode_client_frame(OP_TEXT, payload))
      end

      # Yields each decoded text message until the connection closes or the
      # shutdown flag flips. Replies to pings with pongs internally.
      def each_message
        loop do
          break if @shutdown_flag.value

          frame = read_frame
          next if frame.nil? # timeout tick — recheck shutdown

          case frame[:opcode]
          when OP_TEXT  then yield frame[:payload]
          when OP_PING  then @socket.write(self.class.encode_client_frame(OP_PONG, frame[:payload]))
          when OP_CLOSE then break
          end
        end
      end

      def close
        @socket&.write(self.class.encode_client_frame(OP_CLOSE, ""))
      rescue StandardError
        # best effort
      ensure
        @socket&.close
        @socket = nil
      end

      # --- Pure frame helpers (no IO) ---

      def self.encode_client_frame(opcode, payload)
        payload = payload.to_s.dup.force_encoding("BINARY")
        len = payload.bytesize
        mask_key = SecureRandom.random_bytes(4)

        bytes = (+"").b
        bytes << (0x80 | opcode)
        if len < 126
          bytes << (0x80 | len)
        elsif len < 65_536
          bytes << (0x80 | 126)
          bytes << [len].pack("n")
        else
          bytes << (0x80 | 127)
          bytes << [len].pack("Q>")
        end
        bytes << mask_key
        bytes << apply_mask(payload, mask_key)
        bytes
      end

      def self.decode_server_frame(reader)
        b0, b1 = read_exactly(reader, 2).unpack("C2")
        opcode = b0 & 0x0f
        masked = (b1 & 0x80) != 0
        len = b1 & 0x7f
        len = read_exactly(reader, 2).unpack1("n") if len == 126
        len = read_exactly(reader, 8).unpack1("Q>") if len == 127
        mask_key = masked ? read_exactly(reader, 4) : nil
        payload = len.zero? ? "" : read_exactly(reader, len)
        payload = apply_mask(payload, mask_key) if masked
        { opcode: opcode, payload: payload.force_encoding("UTF-8") }
      end

      def self.apply_mask(data, key)
        key_bytes = key.bytes
        data.bytes.each_with_index.map { |byte, i| byte ^ key_bytes[i % 4] }.pack("C*")
      end

      def self.read_exactly(reader, n)
        buf = (+"").b
        while buf.bytesize < n
          chunk = reader.read(n - buf.bytesize)
          raise EOFError, "socket closed" if chunk.nil? || chunk.empty?
          buf << chunk
        end
        buf
      end

      private

      def read_frame
        ready, = IO.select([@socket], nil, nil, @read_timeout)
        return nil unless ready

        self.class.decode_server_frame(@socket)
      rescue EOFError, IOError, OpenSSL::SSL::SSLError
        { opcode: OP_CLOSE, payload: "" }
      end

      def open_socket
        tcp = TCPSocket.new(@uri.host, @port)
        return tcp unless @uri.scheme == "wss"

        ssl = OpenSSL::SSL::SSLSocket.new(tcp)
        ssl.hostname = @uri.host
        ssl.sync_close = true
        ssl.connect
        ssl
      end

      def perform_handshake
        key = SecureRandom.base64(16)
        path = @uri.path.empty? ? "/" : @uri.path
        path = "#{path}?#{@uri.query}" if @uri.query

        request = +"GET #{path} HTTP/1.1\r\n"
        request << "Host: #{@uri.host}:#{@port}\r\n"
        request << "Upgrade: websocket\r\n"
        request << "Connection: Upgrade\r\n"
        request << "Sec-WebSocket-Key: #{key}\r\n"
        request << "Sec-WebSocket-Version: 13\r\n\r\n"
        @socket.write(request)

        status = @socket.gets
        raise "WebSocket handshake failed: #{status.inspect}" unless status&.include?("101")

        headers = read_headers
        expected = Base64.strict_encode64(Digest::SHA1.digest(key + GUID))
        unless headers["sec-websocket-accept"] == expected
          raise "WebSocket handshake: bad Sec-WebSocket-Accept"
        end
      end

      def read_headers
        headers = {}
        while (line = @socket.gets)
          line = line.chomp
          break if line.empty?

          name, value = line.split(":", 2)
          headers[name.downcase.strip] = value.strip if value
        end
        headers
      end
    end
  end
end
```

Add to `lib/agent_daemon.rb` after the `require_relative "agent_daemon/transport/mattermost"` line:

```ruby
require_relative "agent_daemon/mattermost/web_socket"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_mattermost_web_socket.rb`
Expected: PASS (5 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add lib/agent_daemon/mattermost/web_socket.rb lib/agent_daemon.rb test/test_mattermost_web_socket.rb
git commit -m "$(cat <<'EOF'
Add stdlib WebSocket client for Mattermost listener

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Thread replies in the Mattermost transport

**Files:**
- Modify: `lib/agent_daemon/transport/mattermost.rb` (`deliver`, lines 24-42)
- Test: `test/test_transport_mattermost.rb` (add cases)

**Interfaces:**
- Consumes: existing `Transport::Mattermost#deliver(message_data)` and its `post`/resolution helpers.
- Produces: `deliver` now honors `message_data["channel_id"]` (used verbatim, skips name resolution) and `message_data["root_id"]` (added to the post body as `root_id`). Precedence: `channel_id` → `user` → `channel` → `default_channel`.

- [ ] **Step 1: Write the failing tests**

Add to `test/test_transport_mattermost.rb`:

```ruby
  def test_posts_to_channel_id_verbatim_without_resolution
    with_transport(FakeHttp.new(&handler)) do |t, http|
      t.deliver("channel_id" => "chanXYZ", "message" => "in thread")

      assert_equal({ "channel_id" => "chanXYZ", "message" => "in thread" }, JSON.parse(posts(http).first.body))
      # no channel-name resolution requests were made
      assert_empty http.requests.select { |r| r.path.start_with?("/api/v4/teams/team1/channels/name/") }
    end
  end

  def test_includes_root_id_for_threaded_reply
    with_transport(FakeHttp.new(&handler)) do |t, http|
      t.deliver("channel_id" => "chanXYZ", "root_id" => "root123", "message" => "reply")

      body = JSON.parse(posts(http).first.body)
      assert_equal "chanXYZ", body["channel_id"]
      assert_equal "root123", body["root_id"]
      assert_equal "reply", body["message"]
    end
  end

  def test_omits_root_id_when_absent
    with_transport(FakeHttp.new(&handler)) do |t, http|
      t.deliver("channel" => "dev-alerts", "message" => "no thread")

      refute JSON.parse(posts(http).first.body).key?("root_id")
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_transport_mattermost.rb`
Expected: FAIL — `test_posts_to_channel_id_verbatim_without_resolution` raises "unexpected request" (it resolves a nil channel name) and the root_id test lacks `root_id` in the body.

- [ ] **Step 3: Implement the change**

Replace the `deliver` method in `lib/agent_daemon/transport/mattermost.rb` with:

```ruby
      def deliver(message_data)
        channel = presence(message_data["channel"])
        user = presence(message_data["user"])
        explicit_id = presence(message_data["channel_id"])

        if channel && user
          raise "message specifies both channel (#{channel.inspect}) and user (#{user.inspect}); refusing to guess a destination"
        end

        channel_id =
          if explicit_id
            explicit_id
          elsif user
            dm_channel_id(user)
          elsif channel
            channel_id_by_name(channel)
          else
            channel_id_by_name(@default_channel)
          end

        body = { channel_id: channel_id, message: message_data["message"] }
        root_id = presence(message_data["root_id"])
        body[:root_id] = root_id if root_id

        post("/api/v4/posts", body)
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_transport_mattermost.rb`
Expected: PASS (all existing + 3 new cases).

- [ ] **Step 5: Commit**

```bash
git add lib/agent_daemon/transport/mattermost.rb test/test_transport_mattermost.rb
git commit -m "$(cat <<'EOF'
Support channel_id and root_id (thread replies) in Mattermost transport

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `mattermost` trigger config (defaults, dir resolution, validation)

**Files:**
- Modify: `lib/agent_daemon/config.rb` (`VALID_TRIGGER_TYPES`, new `MATTERMOST_TRIGGER_DEFAULTS`, `build_runner`, `build_trigger`, `validate_trigger`)
- Test: `test/test_config_runners.rb` (add cases)

**Interfaces:**
- Produces: a runner config whose `trigger` (`type: "mattermost"`) has resolved `input_dir`/`archive_dir`/`failed_dir` (default `mentions/<name>/{inbox,done,failed}` under `project_path`), `interval` (default 2), and `jitter` (default 0). Validation requires non-empty `base_url`/`token`/`team` strings, a non-empty `channels` String array, and a positive Integer `interval`.

- [ ] **Step 1: Write the failing tests**

Add to `test/test_config_runners.rb` a helper and cases:

```ruby
  def mattermost_runner(overrides = {})
    {
      "name" => "mention-bot",
      "prompt_template" => "prompts/default.txt",
      "trigger" => {
        "type" => "mattermost",
        "base_url" => "https://mm.example.com",
        "token" => "tok",
        "team" => "eng",
        "channels" => ["dev-bots"]
      }
    }.merge(overrides)
  end

  def test_mattermost_trigger_defaults_dirs_and_interval
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      path = write_config(dir, base_config(project_path, [mattermost_runner]))
      config = AgentDaemon::Config.new(path)

      trigger = config.runners.first["trigger"]
      assert_equal File.join(project_path, "mentions/mention-bot/inbox"),  trigger["input_dir"]
      assert_equal File.join(project_path, "mentions/mention-bot/done"),   trigger["archive_dir"]
      assert_equal File.join(project_path, "mentions/mention-bot/failed"), trigger["failed_dir"]
      assert_equal 2, trigger["interval"]
      assert_equal 0, trigger["jitter"]
    end
  end

  def test_mattermost_trigger_rejects_missing_connection_keys
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      runner = mattermost_runner("trigger" => { "type" => "mattermost", "channels" => ["x"] })
      path = write_config(dir, base_config(project_path, [runner]))
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Config.new(path) }
      assert_includes err.message, "trigger.base_url"
      assert_includes err.message, "trigger.token"
      assert_includes err.message, "trigger.team"
    end
  end

  def test_mattermost_trigger_rejects_empty_channels
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      runner = mattermost_runner
      runner["trigger"] = runner["trigger"].merge("channels" => [])
      path = write_config(dir, base_config(project_path, [runner]))
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Config.new(path) }
      assert_includes err.message, "trigger.channels"
    end
  end

  def test_mattermost_trigger_accepts_dir_overrides
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      runner = mattermost_runner
      runner["trigger"] = runner["trigger"].merge("input_dir" => "custom/in")
      path = write_config(dir, base_config(project_path, [runner]))
      config = AgentDaemon::Config.new(path)
      assert_equal File.join(project_path, "custom/in"), config.runners.first["trigger"]["input_dir"]
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_config_runners.rb`
Expected: FAIL — `mattermost` is rejected as an unknown trigger type.

- [ ] **Step 3: Implement the config changes**

In `lib/agent_daemon/config.rb`:

1. Add the defaults constant next to the other trigger defaults (after `FILE_TRIGGER_DEFAULTS`):

```ruby
    MATTERMOST_TRIGGER_DEFAULTS = { "interval" => 2, "jitter" => 0 }.freeze
```

2. Add `"mattermost"` to the valid types:

```ruby
    VALID_TRIGGER_TYPES   = %w[tracker file mattermost].freeze
```

3. In `build_runner`, pass the runner name into `build_trigger`:

```ruby
      runner["trigger"] = build_trigger(runner["trigger"], runner["name"])
```

4. Change `build_trigger`'s signature and add the `mattermost` branch:

```ruby
    def build_trigger(raw_trigger, name = nil)
      return {} unless raw_trigger.is_a?(Hash)

      case raw_trigger["type"]
      when "tracker"
        deep_merge(TRACKER_TRIGGER_DEFAULTS, raw_trigger)
      when "file"
        trigger = deep_merge(FILE_TRIGGER_DEFAULTS, raw_trigger)
        resolve_trigger_dirs(trigger)
      when "mattermost"
        trigger = deep_merge(MATTERMOST_TRIGGER_DEFAULTS, raw_trigger)
        base = name.to_s.empty? ? "mentions" : "mentions/#{name}"
        trigger["input_dir"]   ||= "#{base}/inbox"
        trigger["archive_dir"] ||= "#{base}/done"
        trigger["failed_dir"]  ||= "#{base}/failed"
        resolve_trigger_dirs(trigger)
      else
        raw_trigger
      end
    end

    def resolve_trigger_dirs(trigger)
      %w[input_dir archive_dir failed_dir].each do |key|
        if trigger[key].is_a?(String) && !trigger[key].empty?
          trigger[key] = File.expand_path(trigger[key], @data["project_path"] || "")
        end
      end
      trigger
    end
```

(The `file` branch now reuses `resolve_trigger_dirs` instead of its inline loop — behavior is identical.)

5. Add the `mattermost` validation branch inside `validate_trigger`'s `case type` (after the `when "file"` block):

```ruby
      when "mattermost"
        %w[base_url token team].each do |key|
          unless trigger[key].is_a?(String) && !trigger[key].empty?
            errors << "runner #{runner_label.inspect}: trigger.#{key} is required (String)"
          end
        end
        channels = trigger["channels"]
        unless channels.is_a?(Array) && !channels.empty? &&
               channels.all? { |c| c.is_a?(String) && !c.empty? }
          errors << "runner #{runner_label.inspect}: trigger.channels must be a non-empty list of channel names"
        end
        unless trigger["interval"].is_a?(Integer) && trigger["interval"] > 0
          errors << "runner #{runner_label.inspect}: trigger.interval must be a positive Integer"
        end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_config_runners.rb`
Expected: PASS (existing file/tracker cases unchanged + 4 new mattermost cases).

- [ ] **Step 5: Commit**

```bash
git add lib/agent_daemon/config.rb test/test_config_runners.rb
git commit -m "$(cat <<'EOF'
Add mattermost trigger config defaults and validation

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Consumer runner (`Runner::Mattermost`)

**Files:**
- Create: `lib/agent_daemon/runner/mattermost.rb`
- Modify: `lib/agent_daemon.rb` (add `require_relative "agent_daemon/runner/mattermost"` after the `runner/file` require)
- Test: `test/test_runner_mattermost.rb`

**Interfaces:**
- Consumes: `Runner::File` (inbox poll, archive/failed moves, attempt tracking) and `base_template_variables` from `Runner::Base`.
- Produces: `Runner::Mattermost < Runner::File`. Overrides `render_prompt(path)` to load the work-item YAML and expose its keys (`message`, `channel_id`, `root_id`, `sender`, `channel_name`, `post_id`) as `{{...}}` template variables on top of the runner-config vars. `work_item_key` stays the file basename (inherited).

- [ ] **Step 1: Write the failing test**

Create `test/test_runner_mattermost.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "yaml"
require "fileutils"

class StubShutdownMattermost
  def value = false
end

class TestRunnerMattermost < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @project_path = File.join(@tmpdir, "project")
    @message_dir  = File.join(@project_path, "to_message")
    @input_dir    = File.join(@project_path, "mentions/inbox")
    @archive_dir  = File.join(@project_path, "mentions/done")
    @failed_dir   = File.join(@project_path, "mentions/failed")
    [@message_dir, @input_dir, @archive_dir, @failed_dir].each { |d| FileUtils.mkdir_p(d) }

    @template_path = File.join(@tmpdir, "prompt.txt")
    File.write(@template_path, "From {{sender}} in {{channel_name}} (thread {{root_id}}): {{message}}")

    @runner_config = {
      "name" => "mention-bot",
      "backend" => "claude",
      "agent" => "task-analyst",
      "extra_flags" => "",
      "timeout" => 1200,
      "max_attempts" => 2,
      "prompt_template" => "prompt.txt",
      "prompt_template_path" => @template_path,
      "trigger" => {
        "type" => "mattermost",
        "input_dir" => @input_dir,
        "archive_dir" => @archive_dir,
        "failed_dir" => @failed_dir,
        "interval" => 2
      }
    }

    null_logger = ::Logger.new(File::NULL)
    null_logger.level = ::Logger::FATAL
    AgentDaemon::Log.instance_variable_set(:@logger, null_logger)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def runner
    AgentDaemon::Runner::Mattermost.new(
      @runner_config, @message_dir, @project_path, StubShutdownMattermost.new
    )
  end

  def test_render_prompt_exposes_work_item_fields
    path = File.join(@input_dir, "post1.yml")
    File.write(path, {
      "message" => "@bot do the thing",
      "channel_id" => "chan1",
      "root_id" => "root9",
      "sender" => "ivan",
      "channel_name" => "dev-bots",
      "post_id" => "post1"
    }.to_yaml)

    prompt = runner.send(:render_prompt, path)
    assert_equal "From ivan in dev-bots (thread root9): @bot do the thing", prompt
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `ruby -Ilib -Itest test/test_runner_mattermost.rb`
Expected: FAIL — `uninitialized constant AgentDaemon::Runner::Mattermost`.

- [ ] **Step 3: Implement the consumer**

Create `lib/agent_daemon/runner/mattermost.rb`:

```ruby
# frozen_string_literal: true

require "yaml"

require_relative "file"

module AgentDaemon
  module Runner
    # Consumes mention work-items written by Mattermost::Listener. Inherits the
    # entire inbox-poll / archive / failed / attempt-tracking machinery from
    # Runner::File; only the prompt rendering differs — the YAML fields the
    # listener captured (message, channel_id, root_id, sender, channel_name,
    # post_id) become template variables so the prompt can instruct the agent
    # to reply into the originating thread.
    class Mattermost < File
      private

      def render_prompt(path)
        data = YAML.safe_load_file(path) || {}
        variables = base_template_variables.merge(data.transform_keys(&:to_s))
        @prompt_template.render(variables)
      end
    end
  end
end
```

Add to `lib/agent_daemon.rb` after the `require_relative "agent_daemon/runner/file"` line:

```ruby
require_relative "agent_daemon/runner/mattermost"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `ruby -Ilib -Itest test/test_runner_mattermost.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/agent_daemon/runner/mattermost.rb lib/agent_daemon.rb test/test_runner_mattermost.rb
git commit -m "$(cat <<'EOF'
Add Mattermost mention consumer runner

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Listener (`Mattermost::Listener`)

**Files:**
- Create: `lib/agent_daemon/mattermost/listener.rb`
- Modify: `lib/agent_daemon.rb` (add `require_relative "agent_daemon/mattermost/listener"` after the `mattermost/web_socket` require)
- Test: `test/test_mattermost_listener.rb`

**Interfaces:**
- Consumes: `Mattermost::WebSocket` (Task 1); the trigger config hash with resolved dirs (Task 3); `stub_net_http`/`FakeHttp`/`FakeSuccess` from `test_helper`.
- Produces: `Mattermost::Listener.new(trigger_config, shutdown_flag)` with `run` (Daemon thread entry). Test seams: `handle_event(event_hash)` writes a work-item YAML when the event is a `posted` mention in an allowlisted channel and not from the bot; `stream(ws)` reads JSON messages from a WebSocket-like object and routes them to `handle_event`. `bot_id` is resolved once via `GET /api/v4/users/me`.

- [ ] **Step 1: Write the failing tests**

Create `test/test_mattermost_listener.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "yaml"
require "json"
require "fileutils"

class StubShutdownListener
  def value = false
end

class TestMattermostListener < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @input_dir   = File.join(@tmpdir, "mentions/inbox")
    @archive_dir = File.join(@tmpdir, "mentions/done")
    @failed_dir  = File.join(@tmpdir, "mentions/failed")
    [@input_dir, @archive_dir, @failed_dir].each { |d| FileUtils.mkdir_p(d) }

    @trigger = {
      "type" => "mattermost",
      "base_url" => "https://mm.example.com",
      "token" => "bot-token",
      "team" => "eng",
      "channels" => ["dev-bots"],
      "input_dir" => @input_dir,
      "archive_dir" => @archive_dir,
      "failed_dir" => @failed_dir
    }

    null_logger = ::Logger.new(File::NULL)
    null_logger.level = ::Logger::FATAL
    AgentDaemon::Log.instance_variable_set(:@logger, null_logger)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  # users/me always resolves the bot id "bot1".
  def me_http
    FakeHttp.new { |req| FakeSuccess.new(JSON.generate(id: "bot1")) }
  end

  def listener
    AgentDaemon::Mattermost::Listener.new(@trigger, StubShutdownListener.new)
  end

  # Builds a Mattermost `posted` event with the given post + data fields.
  def posted_event(post:, mentions: ["bot1"], channel_name: "dev-bots", sender: "ivan")
    {
      "event" => "posted",
      "data" => {
        "channel_name" => channel_name,
        "sender_name" => sender,
        "mentions" => JSON.generate(mentions),
        "post" => JSON.generate(post)
      }
    }
  end

  def inbox_files
    Dir.glob(File.join(@input_dir, "*.yml"))
  end

  def test_writes_work_item_for_allowlisted_mention
    stub_net_http(me_http) do
      listener.handle_event(posted_event(post: {
        "id" => "post1", "user_id" => "user9", "channel_id" => "chan1",
        "root_id" => "", "message" => "@bot help"
      }))
    end

    assert_equal 1, inbox_files.size
    data = YAML.safe_load_file(inbox_files.first)
    assert_equal "post1", data["post_id"]
    assert_equal "chan1", data["channel_id"]
    assert_equal "post1", data["root_id"]   # empty root_id ⇒ open thread on the mention
    assert_equal "ivan", data["sender"]
    assert_equal "dev-bots", data["channel_name"]
    assert_equal "@bot help", data["message"]
  end

  def test_uses_existing_thread_root_when_present
    stub_net_http(me_http) do
      listener.handle_event(posted_event(post: {
        "id" => "post2", "user_id" => "user9", "channel_id" => "chan1",
        "root_id" => "rootA", "message" => "@bot more"
      }))
    end
    assert_equal "rootA", YAML.safe_load_file(inbox_files.first)["root_id"]
  end

  def test_ignores_post_from_the_bot_itself
    stub_net_http(me_http) do
      listener.handle_event(posted_event(post: {
        "id" => "post3", "user_id" => "bot1", "channel_id" => "chan1",
        "root_id" => "", "message" => "@bot loop?"
      }))
    end
    assert_empty inbox_files
  end

  def test_ignores_channel_not_in_allowlist
    stub_net_http(me_http) do
      listener.handle_event(posted_event(channel_name: "random", post: {
        "id" => "post4", "user_id" => "u", "channel_id" => "c", "root_id" => "", "message" => "@bot"
      }))
    end
    assert_empty inbox_files
  end

  def test_ignores_when_bot_not_mentioned
    stub_net_http(me_http) do
      listener.handle_event(posted_event(mentions: ["someoneElse"], post: {
        "id" => "post5", "user_id" => "u", "channel_id" => "c", "root_id" => "", "message" => "hi"
      }))
    end
    assert_empty inbox_files
  end

  def test_dedupes_by_post_id_across_inbox_and_done
    File.write(File.join(@archive_dir, "post6.yml"), "already processed")
    stub_net_http(me_http) do
      listener.handle_event(posted_event(post: {
        "id" => "post6", "user_id" => "u", "channel_id" => "c", "root_id" => "", "message" => "@bot dup"
      }))
    end
    assert_empty inbox_files
  end

  def test_stream_routes_messages_to_handle_event
    fake_ws = Object.new
    event_json = JSON.generate(posted_event(post: {
      "id" => "post7", "user_id" => "u", "channel_id" => "c", "root_id" => "", "message" => "@bot stream"
    }))
    fake_ws.define_singleton_method(:each_message) { |&blk| blk.call(event_json) }

    stub_net_http(me_http) { listener.stream(fake_ws) }
    assert_equal ["post7"], inbox_files.map { |f| File.basename(f, ".yml") }
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_mattermost_listener.rb`
Expected: FAIL — `uninitialized constant AgentDaemon::Mattermost::Listener`.

- [ ] **Step 3: Implement the listener**

Create `lib/agent_daemon/mattermost/listener.rb`:

```ruby
# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "time"
require "fileutils"

require_relative "web_socket"

module AgentDaemon
  module Mattermost
    # Daemon-managed thread that holds a WebSocket to the Mattermost Bot API and
    # turns @-mentions of the bot into work-item YAML files. Peer to the
    # Messenger: communicates with the rest of the daemon only through the
    # filesystem (the inbox dir a Runner::Mattermost consumes). Reconnects with
    # capped exponential backoff so transient drops don't crash the thread.
    class Listener
      BACKOFF_START = 1
      BACKOFF_MAX = 30

      def initialize(trigger_config, shutdown_flag)
        @base_url = URI(trigger_config.fetch("base_url"))
        @token = trigger_config.fetch("token")
        @channels = trigger_config.fetch("channels")
        @input_dir = trigger_config.fetch("input_dir")
        @seen_dirs = [
          trigger_config.fetch("input_dir"),
          trigger_config.fetch("archive_dir"),
          trigger_config.fetch("failed_dir")
        ]
        @shutdown_flag = shutdown_flag
        @backoff = BACKOFF_START
      end

      def run
        Log.info("[#{log_tag}] Thread started")

        until @shutdown_flag.value
          connect_and_stream
          backoff_sleep unless @shutdown_flag.value
        end

        Log.info("[#{log_tag}] Thread stopping gracefully")
      end

      # Read events from a connected WebSocket-like object and route each to
      # handle_event. Separated from run so it is testable with a fake ws.
      def stream(ws)
        ws.each_message do |raw|
          break if @shutdown_flag.value

          event = parse(raw)
          handle_event(event) if event
        end
      end

      # Pure-ish: given a parsed Mattermost event hash, write a work-item if it
      # is a `posted` mention of the bot in an allowlisted channel.
      def handle_event(event)
        return unless event["event"] == "posted"

        data = event["data"] || {}
        post = parse(data["post"]) || {}
        return if post["user_id"] == bot_id
        return unless @channels.include?(data["channel_name"])
        return unless mentioned?(data)

        write_work_item(post, data)
      end

      private

      def log_tag
        "Listener"
      end

      def connect_and_stream
        ws = WebSocket.new(websocket_url, @shutdown_flag).connect
        authenticate(ws)
        @backoff = BACKOFF_START
        stream(ws)
      rescue => e
        Log.warn("[#{log_tag}] connection error, will reconnect: #{e.message}")
      ensure
        ws&.close
      end

      def authenticate(ws)
        ws.send_text(JSON.generate(
          seq: 1,
          action: "authentication_challenge",
          data: { token: @token }
        ))
      end

      def websocket_url
        scheme = @base_url.scheme == "https" ? "wss" : "ws"
        host = @base_url.port ? "#{@base_url.host}:#{@base_url.port}" : @base_url.host
        "#{scheme}://#{host}/api/v4/websocket"
      end

      def mentioned?(data)
        raw = data["mentions"]
        return false unless raw

        mentions = parse(raw)
        mentions.is_a?(Array) && mentions.include?(bot_id)
      end

      def write_work_item(post, data)
        post_id = post["id"]
        filename = "#{post_id}.yml"
        return if already_seen?(filename)

        FileUtils.mkdir_p(@input_dir)
        root = post["root_id"].to_s.empty? ? post_id : post["root_id"]
        content = {
          "message" => post["message"],
          "channel_id" => post["channel_id"],
          "root_id" => root,
          "sender" => data["sender_name"],
          "channel_name" => data["channel_name"],
          "post_id" => post_id,
          "created_at" => Time.now.iso8601
        }
        ::File.write(::File.join(@input_dir, filename), content.to_yaml)
        Log.info("[#{log_tag}] wrote mention #{post_id} from #{data['sender_name']} in #{data['channel_name']}")
      end

      def already_seen?(filename)
        @seen_dirs.any? { |dir| ::File.exist?(::File.join(dir, filename)) }
      end

      def bot_id
        @bot_id ||= http_get("/api/v4/users/me").fetch("id")
      end

      def parse(raw)
        JSON.parse(raw) if raw
      rescue JSON::ParserError
        nil
      end

      def http_get(path)
        req = Net::HTTP::Get.new(path)
        req["Authorization"] = "Bearer #{@token}"
        response = http.request(req)
        unless response.is_a?(Net::HTTPSuccess)
          raise "Mattermost GET #{path} returned #{response.code}"
        end
        JSON.parse(response.body.to_s)
      end

      def http
        @http ||= begin
          h = Net::HTTP.new(@base_url.host, @base_url.port)
          h.use_ssl = @base_url.scheme == "https"
          h.open_timeout = 10
          h.read_timeout = 10
          h
        end
      end

      def backoff_sleep
        seconds = @backoff
        @backoff = [@backoff * 2, BACKOFF_MAX].min
        elapsed = 0
        while elapsed < seconds && !@shutdown_flag.value
          sleep(1)
          elapsed += 1
        end
      end
    end
  end
end
```

Add to `lib/agent_daemon.rb` after the `require_relative "agent_daemon/mattermost/web_socket"` line:

```ruby
require_relative "agent_daemon/mattermost/listener"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_mattermost_listener.rb`
Expected: PASS (7 cases).

- [ ] **Step 5: Commit**

```bash
git add lib/agent_daemon/mattermost/listener.rb lib/agent_daemon.rb test/test_mattermost_listener.rb
git commit -m "$(cat <<'EOF'
Add Mattermost WebSocket listener that writes mention work-items

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Daemon wiring (listener + consumer thread pair)

**Files:**
- Modify: `lib/agent_daemon/daemon.rb` (`build_runner_factories`, `runner_factory_for`, add `factories_for`, `listener_factory_for`, `listener_key`)
- Test: `test/test_daemon.rb` (add cases)

**Interfaces:**
- Consumes: `Runner::Mattermost` (Task 4), `Mattermost::Listener` (Task 5), and the resolved `mattermost` trigger config (Task 3).
- Produces: `build_runner_factories` registers two keys for a `mattermost` runner — `:"runner:<name>"` (a `Runner::Mattermost` factory) and `:"listener:<name>"` (a `Mattermost::Listener` factory). `monitor_threads` restarts each independently (unchanged). `tracker`/`file` runners still register exactly one key each.

- [ ] **Step 1: Write the failing tests**

Add to `test/test_daemon.rb`:

```ruby
  def mattermost_runner(name)
    {
      "name" => name,
      "prompt_template" => File.basename(@template),
      "trigger" => {
        "type" => "mattermost",
        "base_url" => "https://mm.example.com",
        "token" => "tok",
        "team" => "eng",
        "channels" => ["dev-bots"]
      }
    }
  end

  def test_mattermost_runner_registers_listener_and_consumer
    config = make_config([mattermost_runner("bot")])
    daemon = AgentDaemon::Daemon.new(config)
    daemon.send(:build_runner_factories)

    factories = daemon.instance_variable_get(:@runner_factories)
    assert factories.key?(:"runner:bot"),   "expected a consumer factory"
    assert factories.key?(:"listener:bot"), "expected a listener factory"
  end

  def test_mattermost_consumer_factory_builds_runner_mattermost
    config = make_config([mattermost_runner("bot")])
    daemon = AgentDaemon::Daemon.new(config)
    factory = daemon.send(:runner_factory_for, config.runners.first)
    assert_instance_of AgentDaemon::Runner::Mattermost, factory.call
  end

  def test_mattermost_listener_factory_builds_listener
    config = make_config([mattermost_runner("bot")])
    daemon = AgentDaemon::Daemon.new(config)
    factory = daemon.send(:listener_factory_for, config.runners.first)
    assert_instance_of AgentDaemon::Mattermost::Listener, factory.call
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_daemon.rb`
Expected: FAIL — `runner_factory_for` raises `ArgumentError` (unknown trigger type `mattermost`) and `listener_factory_for` is undefined.

- [ ] **Step 3: Implement the wiring**

In `lib/agent_daemon/daemon.rb`:

1. Replace the runner loop in `build_runner_factories` (the `@config.runners.each` block) with:

```ruby
      @config.runners.each do |runner_config|
        factories_for(runner_config).each do |key, factory|
          @runner_factories[key] = factory
        end
      end
```

2. Add `factories_for` (returns one or two `{key => factory}` entries per runner):

```ruby
    # Most triggers map to one thread (runner:<name>). A mattermost trigger also
    # needs a listener thread (listener:<name>) holding the WebSocket; both are
    # Daemon-managed so monitor_threads restarts each independently.
    def factories_for(runner_config)
      name = runner_config.fetch("name")
      factories = { thread_key(name) => runner_factory_for(runner_config) }

      if runner_config.fetch("trigger").fetch("type") == "mattermost"
        factories[listener_key(name)] = listener_factory_for(runner_config)
      end

      factories
    end
```

3. Add the `mattermost` consumer branch to `runner_factory_for`'s `case type` (before the `else`):

```ruby
      when "mattermost"
        -> { Runner::Mattermost.new(runner_config, message_dir, project_path, @shutdown_flag) }
```

4. Add the listener factory and key helpers (next to `thread_key`):

```ruby
    def listener_factory_for(runner_config)
      trigger = runner_config.fetch("trigger")
      -> { Mattermost::Listener.new(trigger, @shutdown_flag) }
    end

    def listener_key(runner_name)
      :"listener:#{runner_name}"
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_daemon.rb`
Expected: PASS (existing per-runner cases unchanged + 3 new mattermost cases).

- [ ] **Step 5: Commit**

```bash
git add lib/agent_daemon/daemon.rb test/test_daemon.rb
git commit -m "$(cat <<'EOF'
Wire mattermost runner into a listener + consumer thread pair

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Docs, example config, prompt, changelog, version bump

**Files:**
- Modify: `docs/architecture.md`
- Modify: `examples/config.yml`
- Create: `examples/prompts/mention.txt`
- Modify: `CHANGELOG.md`
- Modify: `lib/agent_daemon/version.rb`

**Interfaces:**
- Consumes: all prior tasks (documents the shipped behavior).
- Produces: no code interfaces — release artifacts only.

- [ ] **Step 1: Run the full suite (baseline green before doc changes)**

Run: `rake test`
Expected: PASS, 0 failures, 0 errors.

- [ ] **Step 2: Document the trigger and listener in `docs/architecture.md`**

Under the Runners section (after `### Runner::File`), add:

```markdown
### Runner::Mattermost

Consumes mention work-items written by the Mattermost listener (see below).
Subclasses `Runner::File` — same inbox-poll, archive/failed, and attempt
machinery — but renders the prompt from the work-item YAML fields (`message`,
`channel_id`, `root_id`, `sender`, `channel_name`, `post_id`) so the agent can
reply into the originating thread.
```

Add a new top-level section after the Messenger section:

```markdown
## Mattermost listener

When a runner's `trigger.type` is `mattermost`, the Daemon starts a **second**
thread alongside the consumer: `Mattermost::Listener` (a peer to the Messenger).
It holds a stdlib WebSocket (`lib/agent_daemon/mattermost/web_socket.rb`, an
RFC 6455 client over `socket`/`openssl`) to `wss://<base_url>/api/v4/websocket`,
authenticates with the bot token via an `authentication_challenge`, and listens
for `posted` events.

A post becomes a work-item only when all three hold: it is **not** from the bot
(`user_id != bot_id`), its channel is in the configured `channels` allowlist,
and the bot id appears in the event's `mentions`. The listener writes
`<post_id>.yml` (the id also de-dupes against the inbox/done/failed dirs) into
the consumer's `input_dir`. The reply path reuses the Messenger: the agent
writes a message YAML carrying `channel_id` + `root_id`, and the `mattermost`
transport posts it back into the thread.

The connection reconnects with capped exponential backoff (1s → 30s); only
unexpected exceptions bubble up to the Daemon's 60s crash-restart. Mentions that
arrive while the connection is down are not replayed (best-effort live
delivery).
```

In the "Message routing" subsection, document the new reply fields:

```markdown
- `channel_id: <id>` — post to that channel id verbatim (skips name lookup);
  used by mention replies that already know the numeric id.
- `root_id: <post-id>` — post as a threaded reply under that root.
```

Update the Path Resolution table to note the `mattermost` trigger dirs resolve
relative to `project_path` (default `mentions/<name>/{inbox,done,failed}`), and
add `mattermost` to the trigger-type list under Validation.

- [ ] **Step 3: Add a commented example to `examples/config.yml`**

Add a runner entry illustrating the trigger (place it among the other runner
examples), matching the file's existing comment style:

```yaml
  # Mattermost mention bot: runs when the bot is @-mentioned in an allowlisted
  # channel and replies in the same thread. Starts two threads internally — a
  # WebSocket listener and a file-poll consumer.
  - name: mention-bot
    backend: claude
    agent: task-analyst
    prompt_template: prompts/mention.txt
    trigger:
      type: mattermost
      base_url: https://mm.example.com      # same server as the messenger
      token: <%= secret('MM_BOT_TOKEN') %>  # bot token (usually the messenger's)
      team: eng
      channels:                             # allowlist — required, non-empty
        - dev-bots
      interval: 2                           # consumer poll cadence (seconds)
      # input_dir/archive_dir/failed_dir default to mentions/<name>/{inbox,done,failed}
```

- [ ] **Step 4: Create the example prompt `examples/prompts/mention.txt`**

```text
You were mentioned in Mattermost by {{sender}} in #{{channel_name}}.

Their message:
{{message}}

Do what they asked. When you are done, reply in the same thread by writing a
YAML file into {{message_dir}} with these keys:

  message: <your reply text>
  channel_id: "{{channel_id}}"
  root_id: "{{root_id}}"

Write exactly one such file. Keep the reply concise.
```

- [ ] **Step 5: Update `CHANGELOG.md` and bump the version**

Add a new entry at the top of `CHANGELOG.md` (match the existing format):

```markdown
## [0.5.0]

### Added
- `mattermost` trigger: run an agent task when the bot is @-mentioned in an
  allowlisted Mattermost channel, replying in the same thread. Backed by a new
  stdlib RFC 6455 WebSocket client and a Daemon-managed listener thread.
- Mattermost transport now supports `channel_id` (verbatim) and `root_id`
  (threaded replies) routing fields.
```

Set `lib/agent_daemon/version.rb`:

```ruby
  VERSION = "0.5.0"
```

- [ ] **Step 6: Run the full suite and build the gem**

Run: `rake test`
Expected: PASS, 0 failures, 0 errors.

Run: `gem build agent_daemon.gemspec`
Expected: builds `agent_daemon-0.5.0.gem` with no errors.

- [ ] **Step 7: Commit**

```bash
git add docs/architecture.md examples/config.yml examples/prompts/mention.txt CHANGELOG.md lib/agent_daemon/version.rb
git commit -m "$(cat <<'EOF'
Document mattermost trigger; example config, prompt; release 0.5.0

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:**

| Spec item | Task |
|-----------|------|
| Stdlib RFC 6455 WebSocket client (handshake, framing, ping/pong, shutdown-aware reads) | 1 |
| Transport: `channel_id` verbatim + `root_id` threading | 2 |
| Config: `mattermost` type, defaults (`interval` 2, `jitter` 0), default `mentions/<name>/{inbox,done,failed}` dirs, validation (base_url/token/team/channels/interval) | 3 |
| Consumer `Runner::Mattermost < Runner::File`, YAML fields → prompt vars | 4 |
| Listener: bot-id resolution, self-ignore, channel allowlist, mention detection, work-item YAML (incl. root_id thread-vs-root), de-dup, reconnect/backoff, auth challenge | 5 |
| Daemon: one `mattermost` entry → `listener:<name>` + `runner:<name>` pair | 6 |
| Docs, example config, example prompt, changelog, version bump | 7 |
| Sequential processing | inherited from `Runner::File`/`Base` (no concurrency added) — 4/6 |
| Best-effort (no replay), ignore edits/deletions/DMs | 5 (only `posted` events handled; allowlist excludes DMs) + documented in 7 |

**Placeholder scan:** No TBD/TODO; every code and test step contains complete content; commit messages are concrete.

**Type consistency:** `encode_client_frame`/`decode_server_frame`/`apply_mask`/`read_exactly` names match between Task 1 implementation and its tests, and `decode_server_frame` is reused by `read_frame`. `handle_event`/`stream`/`bot_id` names match between Task 5 implementation and tests. `factories_for`/`runner_factory_for`/`listener_factory_for`/`listener_key`/`thread_key` are consistent across Task 6. Work-item YAML keys (`message`, `channel_id`, `root_id`, `sender`, `channel_name`, `post_id`, `created_at`) are identical in the listener (Task 5), the consumer test (Task 4), and the example prompt (Task 7). The transport reply fields (`channel_id`, `root_id`) match between Task 2 and the listener/prompt.

**Notes for the implementer:**
- The WebSocket client's full connect path is covered by a real `TCPServer` integration test (Task 1). The listener's `run`/reconnect loop is not exercised end-to-end against a live Mattermost server in CI; its logic is covered via `handle_event` and `stream` seams (Task 5). A manual smoke test against a real bot token is recommended before release.
- `read(n)` on `OpenSSL::SSL::SSLSocket` blocks until `n` bytes or EOF, which is why frame reads are guarded by `IO.select` for shutdown responsiveness *before* a frame starts; mid-frame reads are expected to complete promptly.
