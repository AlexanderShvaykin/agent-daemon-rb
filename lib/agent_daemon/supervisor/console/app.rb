# frozen_string_literal: true

require "rack"

require_relative "auth"

module AgentDaemon
  module Supervisor
    module Console
      # The console's authenticated surface — plain Rack, no router gem, no
      # Sinatra. `/` is the fleet list (Story 2.3): every supervised entity,
      # grouped by workflow, with liveness derived from the read model
      # (Fleet, itself backed by StateRegistry, AD-4). Runner detail is 2.4,
      # the activity log 2.5, SSE 2.6 — this app reads neither EventBus nor
      # per-runner fields yet.
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

        def initialize(fleet:)
          @fleet = fleet
        end

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
        # GitLab, entity/workflow names from operator-authored config — not
        # agent-influenced today, but 2.4/2.5 put genuinely agent-influenced
        # values (work-item keys) into this same table, so this page escapes
        # by habit rather than by threat model.
        def page(username, csrf_token)
          <<~HTML
            <!DOCTYPE html>
            <html lang="en">
            <head><meta charset="utf-8"><title>agent-daemon console</title></head>
            <body>
            <h1>agent-daemon console</h1>
            <p>Signed in as <strong>#{esc(username)}</strong></p>
            <form method="post" action="/auth/logout">
            <input type="hidden" name="_csrf" value="#{esc(csrf_token)}">
            <button type="submit">Log out</button>
            </form>
            #{fleet_html}
            </body>
            </html>
          HTML
        end

        # One #entries call, two projections of it: every row on the page then
        # comes from a single registry read, which is also one mutex
        # acquisition instead of two per request.
        def fleet_html
          entries = @fleet.entries
          workflows = @fleet.workflows(entries)
          fleet_wide = @fleet.fleet_wide(entries)

          return "<p>No supervised entities.</p>" if workflows.empty? && fleet_wide.empty?

          html = +""
          workflows.each do |name, entries|
            html << "<h2>#{esc(name)}</h2>\n"
            html << entity_table(entries)
          end
          unless fleet_wide.empty?
            html << "<h2>Fleet-wide</h2>\n"
            html << entity_table(fleet_wide)
          end
          html
        end

        def entity_table(entries)
          rows = entries.map { |entry| entity_row(entry) }.join
          <<~HTML
            <table>
            <tr><th>Entity</th><th>Kind</th><th>Liveness</th><th>Note</th><th></th></tr>
            #{rows}</table>
          HTML
        end

        def entity_row(entry)
          <<~HTML
            <tr><td>#{esc(entry.name)}</td><td>#{esc(entry.kind)}</td><td>#{liveness_cell(entry.liveness)}</td><td>#{esc(note_for(entry.status))}</td><td>#{restart_placeholder}</td></tr>
          HTML
        end

        def liveness_cell(liveness)
          %(<span class="liveness liveness-#{esc(liveness)}">#{esc(liveness)}</span>)
        end

        # AC3's FR3 boundary: a runner that exited without the crash flag is
        # not auto-restarted, and that must be visible here, not inferred
        # from the liveness word alone.
        # :stopped is the whole fleet's state for the length of the drain —
        # stop_console runs in Master#start's ensure, AFTER wait_for_threads,
        # so the console keeps serving for up to JOIN_TIMEOUT per supervisor.
        # Without this branch every row reads `dead` with no explanation,
        # indistinguishable from a fleet that has fallen over.
        def note_for(status)
          case status
          when :exited then "exited cleanly — not auto-restarted"
          when :stopped then "stopped — fleet is shutting down"
          when nil then "no state published — never started, or failed to start"
          else ""
          end
        end

        # AC2/AD-13: every supervised entity gets a restart action, disabled
        # until Epic 4 adds the endpoint. No <form>, no action, no POST
        # target — a form pointing at a route that does not exist yet is a
        # 404 waiting to be mistaken for a bug.
        def restart_placeholder
          '<button type="button" disabled>Restart</button>'
        end

        def esc(value)
          Rack::Utils.escape_html(value.to_s)
        end
      end
    end
  end
end
