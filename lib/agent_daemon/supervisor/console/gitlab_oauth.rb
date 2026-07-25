# frozen_string_literal: true

require "oauth2"

# TRANSPORT_ERRORS below names these at class-definition time. They resolve
# today only because oauth2 happens to load them; requiring them explicitly
# means a change of HTTP backend inside oauth2 cannot turn this file into a
# NameError at load, which would take the console down at boot.
require "faraday"
require "json"

module AgentDaemon
  module Supervisor
    module Console
      # The console's ONLY network seam (AD-7): the GitLab OAuth authorization
      # -code flow plus the two API reads the group check needs. Every test
      # doubles this object rather than a socket (Epic 1 retro AI-2).
      #
      # Fail-closed is the whole contract here. Every failure — transport,
      # protocol, malformed body, runaway pagination — raises Error. Nothing in
      # this class returns an empty or partial group list on failure: the caller
      # cannot distinguish that from "this user is in no allowed group", and the
      # difference between those two is the difference between denying an
      # attacker and admitting one.
      #
      # AD-5 isolation: reachable only from the console tree, so the oauth2 gem
      # never enters the core `require "agent_daemon"` graph.
      class GitlabOAuth
        Error = Class.new(StandardError)

        # read_api, NOT read_user. read_user cannot see group membership, so the
        # group check would silently receive [] and deny every user — a
        # fail-open-by-omission in the other direction, and a login nobody can
        # complete.
        SCOPE = "read_api"

        # Only actual memberships (>= Guest), inherited ones included. Without
        # it GitLab returns every group merely VISIBLE to the user, turning the
        # allowed-group check into "anyone who can see the group".
        MIN_ACCESS_LEVEL = 10
        PER_PAGE = 100

        # A server that keeps advertising a next page must not spin forever.
        # 20 pages * 100 = 2000 groups, far past any real membership list.
        MAX_PAGES = 20

        OPEN_TIMEOUT = 5
        TIMEOUT = 10

        # Wall-clock budget for one login's network work. The per-request
        # timeouts above bound a single call but not the sequence: exchange +
        # username + MAX_PAGES pages is minutes on one Puma thread, and with
        # max_threads at its default a handful of concurrent logins against a
        # slow GitLab would exhaust the pool and take /healthz down with it.
        # Auth checks this between calls; #member_group_paths checks it across
        # pagination, which is where the long tail lives.
        DEADLINE = 30

        # Every exception the oauth2/faraday stack can throw at us. Listed
        # explicitly rather than rescuing StandardError so a bug in THIS file
        # still surfaces as a bug instead of being laundered into "GitLab is
        # down".
        TRANSPORT_ERRORS = [OAuth2::Error, Faraday::Error, JSON::ParserError].freeze

        def initialize(host:, app_id:, app_secret:, redirect_uri:)
          @redirect_uri = redirect_uri
          @client = OAuth2::Client.new(
            app_id,
            app_secret,
            site: host,
            authorize_url: "/oauth/authorize",
            token_url: "/oauth/token",
            connection_opts: { request: { timeout: TIMEOUT, open_timeout: OPEN_TIMEOUT } }
          )
        end

        def authorize_url(state:)
          @client.auth_code.authorize_url(redirect_uri: @redirect_uri, scope: SCOPE, state: state)
        end

        # redirect_uri must be byte-identical to the one in #authorize_url or
        # GitLab rejects the code — hence the single @redirect_uri built once by
        # the caller and used by both.
        def exchange(code:)
          @client.auth_code.get_token(code, redirect_uri: @redirect_uri)
        rescue *TRANSPORT_ERRORS => e
          # Only the exception CLASS is reported: an OAuth2::Error message can
          # quote the request that produced it, credentials included.
          raise Error, "token exchange failed (#{e.class})"
        end

        def fetch_username(token)
          body = get(token, "/api/v4/user")
          username = body["username"] if body.is_a?(Hash)
          raise Error, "user lookup returned no username" unless username.is_a?(String) && !username.empty?

          username
        end

        # Every group path the user is actually a member of, inherited
        # memberships included (GitLab expands those server-side, which is why
        # the caller can compare with plain equality).
        def member_group_paths(token)
          paths = []
          page = 1
          deadline = monotonic + DEADLINE

          MAX_PAGES.times do
            # A server that answers slowly enough, page after page, is as bad
            # as one that never answers at all — and MAX_PAGES alone does not
            # bound wall-clock time.
            raise Error, "group lookup exceeded the #{DEADLINE}s budget" if monotonic > deadline

            body = get(token, "/api/v4/groups",
                       params: { min_access_level: MIN_ACCESS_LEVEL, per_page: PER_PAGE, page: page },
                       response: :with_headers)
            entries, headers = body
            raise Error, "group lookup returned #{entries.class}, expected a list" unless entries.is_a?(Array)

            paths.concat(entries.filter_map { |entry| entry["full_path"] if entry.is_a?(Hash) })

            next_page = headers["x-next-page"].to_s
            return paths if next_page.empty?

            page = next_page.to_i
          end

          raise Error, "group lookup returned too many pages (>#{MAX_PAGES})"
        end

        private

        # One place where transport failures become Error, so no caller can
        # accidentally let one through as a nil/empty success.
        def get(token, path, params: nil, response: :parsed)
          opts = params ? { params: params } : {}
          result = token.get(path, opts)
          response == :with_headers ? [result.parsed, result.headers] : result.parsed
        rescue *TRANSPORT_ERRORS => e
          raise Error, "#{path == '/api/v4/user' ? 'user' : 'group'} lookup failed (#{e.class})"
        end

        def monotonic
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
