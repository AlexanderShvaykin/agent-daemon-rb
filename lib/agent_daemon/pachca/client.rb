# frozen_string_literal: true

require "net/http"
require "json"
require "securerandom"
require "uri"

module AgentDaemon
  module Pachca
    # Thin stdlib client over Pachca's REST API, covering exactly what the
    # poller trigger needs: read the bot's retained event history, and
    # acknowledge one event by deleting it.
    #
    # Pachca has no realtime API — outgoing webhooks and this history endpoint
    # are the only two ways to receive events — and the history needs no public
    # URL at all (the bot's "save event history" setting works with an empty
    # Webhook URL). Read plus delete makes it a queue with an explicit ack,
    # which is why the trigger is an ordinary poller and not an HTTP server.
    class Client
      DEFAULT_BASE_URL = "https://api.pachca.com"
      API_PREFIX       = "/api/shared/v1"
      DEFAULT_BACKOFF  = 60
      DEFAULT_LIMIT    = 50

      # The most any single list request returns (the API's own cap), and the
      # most pages #messages will walk before giving up on a chat.
      MAX_PAGE  = 50
      MAX_PAGES = 20

      # The signed form fields POST /uploads hands back, named here because the
      # S3 policy signs an exact set: an unknown extra field is rejected, and
      # the file part has to come last (the storage stops reading the form
      # there). "key" and "file" are appended by #store, in that order.
      SIGNATURE_FIELDS = %w[Content-Disposition acl policy x-amz-credential
                            x-amz-algorithm x-amz-date x-amz-signature].freeze

      # What Pachca renders inline rather than as an attachment. The API takes
      # the distinction as a given ("image" or "file") and never infers it from
      # the bytes, so a screenshot posted as "file" arrives as a download link.
      IMAGE_EXTENSIONS = %w[.png .jpg .jpeg .gif .webp .bmp .heic .heif].freeze

      def initialize(config)
        @token           = config.fetch("token")
        @base_url        = URI(config.fetch("base_url", DEFAULT_BASE_URL))
        @default_backoff = config.fetch("default_backoff", DEFAULT_BACKOFF)
      end

      # One page of the bot's retained events, oldest first. Each entry is
      # {"id" => <ULID>, "event_type" => ..., "payload" => {...}, "created_at" => ...}.
      #
      # Sorted here rather than trusted from the API: an event id is a ULID, so
      # lexicographic order is chronological order, and a chat bot must answer
      # the oldest question first whichever way the endpoint happens to page.
      def events(limit: DEFAULT_LIMIT)
        body = get("/webhooks/events?limit=#{limit.to_i}")
        Array(body["data"]).sort_by { |event| event["id"].to_s }
      end

      # Acknowledge one event. Deleting is what keeps the history bounded and
      # what stops a processed event coming back on the next poll. A 404 counts
      # as success: the event is gone, which is the state we asked for.
      def delete_event(id)
        delete("/webhooks/events/#{URI.encode_www_form_component(id.to_s)}")
        true
      end

      # Post one message. `entity_type` is "discussion" (a chat or channel),
      # "thread", or "user" — the last one addresses a person directly and
      # opens the conversation on first contact, so a DM needs no channel
      # created first. `parent_message_id` threads the post as a reply.
      #
      # The API nests everything under a "message" object; a flat body is
      # rejected as a validation error, not silently ignored.
      #
      # `files` are descriptors from #upload, not paths: an upload is an orphan
      # object on the storage until a message references its key, and only this
      # call makes it visible to anyone.
      def create_message(entity_type:, entity_id:, content:, parent_message_id: nil, files: nil)
        message = {
          "entity_type" => entity_type,
          "entity_id" => entity_id,
          "content" => content.to_s
        }
        message["parent_message_id"] = parent_message_id if parent_message_id
        message["files"] = files if files && !files.empty?

        post("/messages", "message" => message)
      end

      # Upload one local file and return the descriptor a message carries in
      # its "files" array: {"key", "name", "file_type", "size"}.
      #
      # Three steps, and the middle one is not Pachca's: POST /uploads signs an
      # S3 form, the bytes go straight to the storage host (no bearer token
      # there — the signature is the authorization), and the key comes back
      # here for #create_message to reference. The file is read into memory,
      # which is what the daemon's own traffic looks like — a chart, a log, a
      # screenshot the agent just produced.
      def upload(path, name: nil, file_type: nil)
        full_path = File.expand_path(path.to_s)
        raise "Pachca upload: #{full_path} is not a readable file" unless File.file?(full_path) && File.readable?(full_path)

        display_name = presence(name) || File.basename(full_path)
        signature = post("/uploads", {})
        # The signed key is a template — the policy fixes the directory and
        # leaves the basename to us.
        key = signature.fetch("key").sub("${filename}", display_name)
        store(signature, key, full_path, display_name)

        {
          "key" => key,
          "name" => display_name,
          "file_type" => presence(file_type) || file_type_for(display_name),
          "size" => File.size(full_path)
        }
      end

      # The most recent messages of a chat, oldest first — the order a
      # transcript is read in, which is not the order the API returns them.
      #
      # `chat_id` accepts a thread's own chat as readily as a channel's, which
      # is what makes this usable for thread context: a message posted in a
      # thread carries that thread's chat in its chat_id.
      #
      # One request returns at most MAX_PAGE, so a larger `limit` is walked
      # back through the cursor. Paging runs newest-first and stops as soon as
      # `limit` is reached, so asking for more than the chat holds costs one
      # extra request, not a scan.
      def messages(chat_id:, limit: MAX_PAGE)
        wanted = Integer(limit)
        return [] unless wanted.positive?

        collected = []
        cursor = nil
        pages = 0

        while collected.size < wanted
          body = get(messages_path(chat_id, [wanted - collected.size, MAX_PAGE].min, cursor))
          page = Array(body["data"])
          collected.concat(page)

          paginate = body["meta"].is_a?(Hash) ? body["meta"]["paginate"] : nil
          next_cursor = paginate.is_a?(Hash) ? paginate["next_page"] : nil

          # Four ways to be done, and the last two are guards rather than
          # conditions: a server that keeps handing back the same cursor, or
          # never stops offering a next page, must not spin this loop forever
          # in front of an agent that has not started yet.
          break if page.empty?
          break if next_cursor.nil? || next_cursor == cursor
          break if (pages += 1) >= MAX_PAGES

          cursor = next_cursor
        end

        collected.sort_by { |message| message["id"].to_i }
      end

      # One message by id. Used for the message a thread hangs off: that one
      # lives in the parent chat, not in the thread, so listing the thread
      # returns everything except the question that started it.
      def message(id)
        body = get("/messages/#{Integer(id)}")
        body["data"] || body
      end

      # The thread hanging off a message, created if it is not there yet. This
      # is what answering "in a thread" requires when the question was a plain
      # channel message: such a message has no thread of its own, so posting
      # back with its entity pair lands in the channel, not under it.
      # Idempotent — an existing thread is returned rather than duplicated.
      def create_thread(message_id)
        body = post("/messages/#{Integer(message_id)}/thread", nil)
        body["data"] || body
      end

      # Put a reaction on a message. `code` is the emoji itself for a stock
      # one; a custom reaction is identified by `name` (":agent-thinking:"),
      # which is what the agent-thinking indicator uses — Pachca renders a live
      # timer instead of a counter for a reaction by that name.
      def add_reaction(message_id, code:, name: nil)
        body = { "code" => code }
        body["name"] = name if name
        post("/messages/#{Integer(message_id)}/reactions", body)
      end

      def remove_reaction(message_id, code:, name: nil)
        body = { "code" => code }
        body["name"] = name if name
        delete("/messages/#{Integer(message_id)}/reactions", body)
      end

      private

      def presence(value)
        value.strip if value.is_a?(String) && !value.strip.empty?
      end

      def file_type_for(name)
        IMAGE_EXTENSIONS.include?(File.extname(name).downcase) ? "image" : "file"
      end

      # POST the bytes to the storage host the signature names. Everything about
      # this request is unlike the rest of the client — another host, no bearer
      # token, no JSON — so it builds its own request rather than going through
      # #request, and the body is assembled by hand: a signed multipart form
      # tolerates no reordering, and Net::HTTP's own #set_form gives no
      # guarantee worth relying on here.
      def store(signature, key, path, name)
        fields = SIGNATURE_FIELDS.filter_map { |field| [field, signature[field]] if signature.key?(field) }
        fields << ["key", key]

        url = URI(signature.fetch("direct_url"))
        boundary = "AgentDaemon-#{SecureRandom.hex(16)}"

        req = Net::HTTP::Post.new(url.request_uri)
        req["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
        req.body = multipart_body(fields, boundary, name, File.binread(path))

        response = storage_http(url).request(req)
        return if response.is_a?(Net::HTTPSuccess)

        raise "Pachca upload to #{url.host} returned #{response.code}: #{response.body.to_s.strip.slice(0, 500)}"
      end

      # Binary throughout: the parts are joined to file bytes, and a UTF-8
      # header string would push the whole body through a transcode that a PNG
      # does not survive.
      def multipart_body(fields, boundary, filename, bytes)
        body = String.new(encoding: Encoding::BINARY)

        fields.each do |name, value|
          body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n".b
        end
        body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\n" \
                "Content-Type: application/octet-stream\r\n\r\n".b
        body << bytes.b
        body << "\r\n--#{boundary}--\r\n".b
      end

      public

      # Downloads an attachment. The url comes from a message's `files` entry:
      # it is a pre-signed storage link, valid for seven days, and carries its
      # own credentials — sending the bot token there would leak it to a third
      # party for nothing.
      #
      # Returns nil rather than raising when the file is bigger than `limit`.
      # Half a PNG is not a picture, and a run that answers without the
      # screenshot beats one that dies over it. Same for a refusal from the
      # storage: it is logged by the caller and the answer goes on without it.
      def fetch_file(url, limit:)
        uri = URI(url.to_s)
        response = storage_http(uri).request(Net::HTTP::Get.new(uri.request_uri))
        return nil unless response.is_a?(Net::HTTPSuccess)

        # Checked twice on purpose: Content-Length lets an oversized file be
        # refused before it is read, and the body length catches a response
        # that did not declare one.
        declared = response["content-length"].to_i
        return nil if declared.positive? && declared > limit

        body = response.body
        return nil if body.nil? || body.bytesize > limit

        body
      end

      private

      # Kept per host: the storage is a different origin from the API, and its
      # read timeout is an upload's, not a JSON round trip's.
      def storage_http(url)
        @storage_http ||= {}
        @storage_http[[url.host, url.port]] ||= begin
          h = Net::HTTP.new(url.host, url.port)
          h.use_ssl = url.scheme == "https"
          h.open_timeout = 15
          h.read_timeout = 120
          h
        end
      end

      # The cursor is opaque and base64, so it carries "=" and "+" and has to
      # be escaped rather than pasted into the query.
      def messages_path(chat_id, limit, cursor)
        path = "/messages?chat_id=#{Integer(chat_id)}&sort=id&order=desc&limit=#{Integer(limit)}"
        path += "&cursor=#{URI.encode_www_form_component(cursor)}" if cursor
        path
      end

      def get(path)
        request(Net::HTTP::Get.new(API_PREFIX + path))
      end

      def delete(path, body = nil)
        req = Net::HTTP::Delete.new(API_PREFIX + path)
        req.body = JSON.generate(body) if body
        request(req, allow_not_found: true)
      end

      def post(path, body)
        req = Net::HTTP::Post.new(API_PREFIX + path)
        req.body = JSON.generate(body) if body
        request(req)
      end

      def request(req, allow_not_found: false)
        req["Authorization"] = "Bearer #{@token}"
        req["Content-Type"]  = "application/json"

        response = http.request(req)

        if response.is_a?(Net::HTTPTooManyRequests)
          raise RateLimitError.new(retry_after_seconds(response), "Pachca API 429: rate limited, retry after #{retry_after_seconds(response)}s")
        end
        return {} if allow_not_found && response.is_a?(Net::HTTPNotFound)

        unless response.is_a?(Net::HTTPSuccess)
          raise "Pachca #{req.method} #{req.path} returned #{response.code}: #{error_detail(response)}"
        end

        body = response.body.to_s
        body.empty? ? {} : JSON.parse(body)
      end

      # Parse the Retry-After header (integer-seconds form only). Absent, blank
      # or non-numeric (an HTTP-date) falls back to the configured backoff, so
      # the caller always gets a usable duration.
      def retry_after_seconds(response)
        value = response["Retry-After"]
        return value.to_i if value.is_a?(String) && value.match?(/\A\d+\z/)

        @default_backoff
      end

      # Pachca reports errors in two JSON shapes — ApiError
      # {"errors":[{key,value,message,code}]} for validation/permission problems
      # and OAuthError {"error","error_description"} for auth ones — but the
      # request-frequency limiter answers text/plain, not JSON. So the body is
      # parsed only when it claims to be JSON, and anything unrecognized is
      # passed through verbatim rather than swallowed.
      def error_detail(response)
        raw = response.body.to_s
        parsed = parse_json_body(response, raw)

        detail =
          if parsed.is_a?(Hash) && parsed["errors"].is_a?(Array)
            parsed["errors"].map { |e| [e["key"], e["message"] || e["code"]].compact.join(" ") }.join("; ")
          elsif parsed.is_a?(Hash) && parsed["error"]
            [parsed["error"], parsed["error_description"]].compact.join(": ")
          else
            raw
          end

        detail.to_s.strip.slice(0, 500)
      end

      def parse_json_body(response, raw)
        return nil unless response["Content-Type"].to_s.include?("json")

        JSON.parse(raw)
      rescue JSON::ParserError
        nil
      end

      def http
        @http ||= begin
          h = Net::HTTP.new(@base_url.host, @base_url.port)
          h.use_ssl = @base_url.scheme == "https"
          h.open_timeout = 15
          h.read_timeout = 30
          h
        end
      end
    end
  end
end
