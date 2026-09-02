# frozen_string_literal: true

require "rack"
require "securerandom"
require "uri"

require_relative "../../log"
require_relative "gitlab_oauth"

module AgentDaemon
  module Supervisor
    module Console
      # The console's single authentication choke-point (AD-7). It wraps the
      # WHOLE app and authenticates BY DEFAULT: a request is served only if its
      # path is on the public allowlist below, or it is one of the auth
      # endpoints this middleware answers itself, or it carries a live
      # authenticated session.
      #
      # This is deliberately not per-route `before` filters. Under filters, the
      # next route someone adds ships open unless they remember to opt in;
      # under this middleware it ships closed unless someone edits
      # PUBLIC_PATHS. That inversion is the security property (security review
      # F1), and it is why the wrapped app contains no auth code at all —
      # it never reads a cookie and never checks a session.
      #
      # AD-5 isolation: reachable only from the console tree.
      class Auth
        # The entire allowlist of paths that reach the WRAPPED APP without a
        # session. Epic 6 adds "/metrics" here; it is the only planned addition.
        # Anything else that needs to be public needs a security decision, not a
        # code change.
        #
        # This is not the whole unauthenticated surface of the process: the
        # three /auth/* paths below are also answered without a session, but
        # they are answered by THIS middleware and never reach the app. Read
        # them as part of the choke-point, not as holes in it.
        PUBLIC_PATHS = %w[/healthz].freeze

        # HEAD is how most probes ask (curl -I, load balancers, several systemd
        # idioms). It reaches the same handler as GET on the same public path,
        # so it widens no surface.
        PUBLIC_METHODS = %w[GET HEAD].freeze

        COOKIE_NAME = "agent_console_session"
        PENDING_COOKIE_NAME = "agent_console_pending"

        # Where the wrapped app reads the logged-in user from.
        SESSION_ENV_KEY = "agent_daemon.session"
        AUTHORIZATION_ENV_KEY = "agent_daemon.authorization"

        LOGIN_PATH = "/auth/login"
        CALLBACK_PATH = "/auth/callback"
        LOGOUT_PATH = "/auth/logout"

        # Never a post-login destination. The three auth legs would loop or
        # land on a dead end; /events is the SSE endpoint, so returning there
        # drops the browser on a raw text/event-stream instead of a page —
        # and an expired stream's own redirect carries exactly that path.
        NON_RETURN_PATHS = [LOGIN_PATH, CALLBACK_PATH, LOGOUT_PATH, "/events", "/restart"].freeze

        STATE_BYTES = 32
        GROUP_RECHECK_INTERVAL = 60

        TEXT_HEADERS = { "content-type" => "text/plain; charset=utf-8" }.freeze

        # Rack raises these out of #params for a query string that exceeds its
        # depth/count limits, carries a bad encoding, or mixes scalar/array
        # shapes. They arrive on paths a client controls entirely, so they are
        # a denial, not a 500.
        PARAM_ERRORS = [Rack::BadRequest].freeze

        MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

        def initialize(app, sessions:, gitlab:, allowed_groups:, secure_cookies: true)
          @app = app
          @sessions = sessions
          @gitlab = gitlab
          @allowed_groups = allowed_groups
          @secure_cookies = secure_cookies
        end

        def call(env)
          request = Rack::Request.new(env)

          if PUBLIC_PATHS.include?(request.path_info) && PUBLIC_METHODS.include?(request.request_method)
            return @app.call(env)
          end

          case request.path_info
          # The two login legs are navigations, so GET is the only verb that can
          # legitimately reach them. Gating them keeps the pre-auth surface to
          # the one verb a browser actually uses.
          when LOGIN_PATH    then request.get? ? start_login(request) : text(405, "method not allowed")
          when CALLBACK_PATH then request.get? ? complete_login(request) : text(405, "method not allowed")
          when LOGOUT_PATH   then logout(request)
          else                    authenticated(request, env)
          end
        end

        private

        # The pending session binds this browser to this `state`; the callback
        # accepts nothing else. #create_pending sweeps expired entries as it
        # goes, which is the store's only reaper.
        def start_login(request)
          query = params(request)
          return text(400, "bad request") unless query

          state = SecureRandom.urlsafe_base64(STATE_BYTES)
          pending = @sessions.create_pending(
            state: state,
            pending_id: pending_session_id(request),
            return_to: local_return_path(query["return_to"])
          )

          # The store is full of live entries, i.e. this endpoint is being
          # flooded. Refusing is the fail-closed answer: no session is minted
          # and nothing already logged in is disturbed.
          unless pending
            Log.warn("[Console] login refused: session store is full")
            return text(503, "login temporarily unavailable")
          end

          redirect(@gitlab.authorize_url(state: state), cookie: [PENDING_COOKIE_NAME, pending.id])
        end

        # Fail-closed throughout: every branch that is not a complete, verified,
        # allowed login ends in 403. Once a matching state is claimed, only that
        # state is consumed; other pending tabs remain usable.
        def complete_login(request)
          query = params(request)
          return deny_login(nil, nil, "malformed callback query") unless query

          # `state` is single-use and session-bound (security review F2: the
          # oauth2 gem supplies no CSRF machinery, the console owns it).
          state = query["state"]
          pending_id = pending_session_id(request)
          return_to = state.is_a?(String) ? @sessions.claim_pending(pending_id, state) : nil
          return deny_login(nil, nil, "state mismatch") unless return_to

          code = query["code"]
          return deny_login(pending_id, state, "callback carried no code") unless code.is_a?(String) && !code.empty?

          begin
            token, username, groups = identify(code)
          rescue GitlabOAuth::Error => e
            # AC3's fail-closed clause: an unknown or failed lookup denies. The
            # message carries the reason class only — never a token or secret.
            return deny_login(pending_id, state, e.message)
          end

          # Exact, case-sensitive full_path equality. GitLab expands inherited
          # membership downward, so a member of an allowed parent group has the
          # parent itself in this list; a user holding only a descendant is
          # denied until an operator lists that descendant (security review F3,
          # read fail-closed).
          unless groups.any? { |group| @allowed_groups.include?(group) }
            return deny_login(pending_id, state, "user #{username.inspect} is in no allowed group")
          end

          # Rotation (AC4 anti-fixation): promote consumes the pending id and
          # mints a fresh one. It returns nil when the pending session died
          # during the network round-trip, which denies like everything else.
          promoted = @sessions.promote(
            pending_id,
            state: state,
            username: username,
            access_token: token,
            replaced_id: session_id(request)
          )
          return deny_login(pending_id, state, "pending login expired during the round-trip") unless promoted

          # The audit trail's positive half: without this line an incident
          # cannot answer "who logged in, and when". The username is the whole
          # point of the record; tokens and app_secret stay out of it.
          Log.info("[Console] login succeeded for #{username.inspect}")
          redirect(return_to, cookie: [COOKIE_NAME, promoted.id])
        end

        # The three network calls share one wall-clock budget. Their per-request
        # timeouts alone allow exchange + username + MAX_PAGES pages, which is
        # minutes on a single Puma thread; with max_threads at its default a
        # handful of concurrent logins against a slow GitLab would take the
        # console down, /healthz included. The budget is checked between calls
        # and again across pagination inside GitlabOAuth.
        def identify(code)
          deadline = MONOTONIC.call + GitlabOAuth::DEADLINE

          token = @gitlab.exchange(code: code)
          check_deadline!(deadline)
          username = @gitlab.fetch_username(token)
          check_deadline!(deadline)

          [token, username, @gitlab.member_group_paths(token)]
        end

        def check_deadline!(deadline)
          return if MONOTONIC.call <= deadline

          raise GitlabOAuth::Error, "login exceeded the #{GitlabOAuth::DEADLINE}s budget"
        end

        # Rack parses lazily, so a hostile query string raises here rather than
        # at the edge. Returning nil turns it into the ordinary denial path
        # instead of a 500 that leaves the pending `state` replayable.
        def params(request)
          request.params
        rescue *PARAM_ERRORS
          nil
        end

        # Logout is a mutation, so it is a CSRF-protected POST (AD-7).
        def logout(request)
          return text(405, "method not allowed") unless request.post?

          session = @sessions.fetch(session_id(request))
          return text(403, "forbidden") unless session&.kind == :authenticated

          supplied = params(request)&.[]("_csrf") || request.get_header("HTTP_X_CSRF_TOKEN")
          return text(403, "forbidden") unless matches?(supplied, session.csrf_token)

          @sessions.destroy(session.id)
          redirect(LOGIN_PATH, cookie: [COOKIE_NAME, :expire])
        end

        def authenticated(request, env)
          id = session_id(request)
          session = @sessions.fetch(id)
          return redirect(login_path_for(request)) unless session&.kind == :authenticated

          env[SESSION_ENV_KEY] = @sessions.public_view(session)
          env[AUTHORIZATION_ENV_KEY] = -> { authorized?(id) }
          @app.call(env)
        end

        def session_id(request)
          request.cookies[COOKIE_NAME]
        end

        def pending_session_id(request)
          request.cookies[PENDING_COOKIE_NAME]
        end

        def authorized?(id)
          @sessions.authorize(id, interval: GROUP_RECHECK_INTERVAL) do |token|
            groups = @gitlab.member_group_paths(token)
            groups.any? { |group| @allowed_groups.include?(group) }
          end
        end

        def login_path_for(request)
          return_to = local_return_path(request.fullpath)
          "#{LOGIN_PATH}?return_to=#{Rack::Utils.escape(return_to)}"
        end

        def local_return_path(candidate)
          return "/" unless candidate.is_a?(String) && candidate.start_with?("/") && !candidate.start_with?("//")

          uri = URI.parse(candidate)
          return "/" if uri.scheme || uri.host
          # Compared with trailing slashes stripped: "/auth/login/" routes to
          # the same place a bare literal match would have let through.
          return "/" if NON_RETURN_PATHS.include?(uri.path.sub(%r{/+\z}, ""))

          candidate
        rescue URI::InvalidURIError
          "/"
        end

        def matches?(supplied, expected)
          return false unless supplied.is_a?(String) && !supplied.empty?
          return false unless expected.is_a?(String) && !expected.empty?

          Rack::Utils.secure_compare(supplied, expected)
        end

        # A denied login is terminal: 403 (never a redirect back to /auth/login,
        # which would loop and hide the cause). A claimed matching state is
        # discarded, while unrelated pending states and any authenticated
        # session remain untouched.
        def deny_login(pending_id, state, reason)
          Log.warn("[Console] login denied: #{reason}")
          @sessions.discard_pending(pending_id, state) if pending_id && state
          text(403, "forbidden")
        end

        # Bodies are fixed strings: nothing a client sent is ever echoed back.
        def text(status, body, cookie: nil)
          [status, headers(TEXT_HEADERS, cookie), [body]]
        end

        def redirect(location, cookie: nil)
          [302, headers(TEXT_HEADERS.merge("location" => location), cookie), []]
        end

        def headers(base, cookie)
          return base.dup if cookie.nil?

          name, value = cookie
          base.merge("set-cookie" => value == :expire ? delete_cookie(name) : set_cookie(name, value))
        end

        # SameSite=Lax, never Strict: the OAuth callback arrives as a top-level
        # cross-site navigation from GitLab, and Strict withholds the cookie on
        # exactly that navigation — the pending session would be unreadable and
        # every login would fail state validation.
        def set_cookie(name, id)
          Rack::Utils.set_cookie_header(
            name,
            value: id,
            path: "/",
            httponly: true,
            same_site: :lax,
            secure: @secure_cookies
          )
        end

        def delete_cookie(name)
          Rack::Utils.delete_set_cookie_header(name, path: "/")
        end
      end
    end
  end
end
