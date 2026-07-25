# frozen_string_literal: true

require "rack"

require_relative "auth"

module AgentDaemon
  module Supervisor
    module Console
      # The console's authenticated surface — plain Rack, no router gem, no
      # Sinatra. In Story 2.2 it is deliberately almost empty: the fleet list is
      # 2.3, runner detail 2.4, the activity log 2.5, SSE 2.6. It reads neither
      # StateRegistry nor EventBus yet.
      #
      # There is NO auth code here, by design. Auth wraps this app and
      # authenticates by default, so a route added below is protected the moment
      # it is written, with no opt-in to forget (security review F1). Adding an
      # auth check here would start eroding that property.
      #
      # AD-5 isolation: reachable only from the console tree.
      class App
        # no-store because this page embeds the session's CSRF token and the
        # logged-in username: a shared machine's Back button after logout, or
        # any intermediary cache, must not be able to serve either back.
        HTML_HEADERS = {
          "content-type" => "text/html; charset=utf-8",
          "cache-control" => "no-store"
        }.freeze
        TEXT_HEADERS = { "content-type" => "text/plain; charset=utf-8" }.freeze

        def call(env)
          request = Rack::Request.new(env)

          case request.path_info
          # HEAD is how most liveness probes ask; the middleware lets it through
          # on this path for the same reason.
          when "/healthz" then probe(request)
          when "/"        then request.get? ? home(env[Auth::SESSION_ENV_KEY]) : not_found
          else                 not_found
          end
        end

        private

        # Deliberately bare (security review F5): liveness for systemd, not a
        # status page. It is the one unauthenticated route, so anything it says
        # it says to the whole internet — including how many runners exist and
        # what they are called. Keep it two bytes.
        #
        # A HEAD response must carry no body per RFC 9110 (and Rack::Lint
        # enforces it); a probe only reads the status anyway.
        def probe(request)
          return not_found unless request.get? || request.head?

          [200, TEXT_HEADERS.dup, request.head? ? [] : ["ok"]]
        end

        # The session is absent only if this app is mounted without its
        # middleware, which the server never does. Render rather than raise: an
        # access decision here would be exactly the auth code this app must not
        # contain.
        def home(session)
          [200, HTML_HEADERS.dup, [page(session&.username.to_s, session&.csrf_token.to_s)]]
        end

        def not_found
          [404, TEXT_HEADERS.dup, ["not found"]]
        end

        # AD-7: every interpolated value is escaped. The username comes from
        # GitLab and is not ours to trust.
        def page(username, csrf_token)
          <<~HTML
            <!DOCTYPE html>
            <html lang="en">
            <head><meta charset="utf-8"><title>agent-daemon console</title></head>
            <body>
            <h1>agent-daemon console</h1>
            <p>Signed in as <strong>#{Rack::Utils.escape_html(username)}</strong></p>
            <form method="post" action="/auth/logout">
            <input type="hidden" name="_csrf" value="#{Rack::Utils.escape_html(csrf_token)}">
            <button type="submit">Log out</button>
            </form>
            </body>
            </html>
          HTML
        end
      end
    end
  end
end
