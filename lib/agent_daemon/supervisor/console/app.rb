# frozen_string_literal: true

require "rack"

require_relative "../../log"
require_relative "auth"

module AgentDaemon
  module Supervisor
    module Console
      # The console's authenticated surface — plain Rack, no router gem, no
      # Sinatra. `/` is the fleet list (Story 2.3): every supervised entity,
      # grouped by workflow, with liveness derived from the read model
      # (Fleet, itself backed by StateRegistry, AD-4). `/entity?id=…` is the
      # per-runner detail page (Story 2.4), which reads the snapshot's
      # per-runner fields — work item, attempt, generation, observed_at. The
      # per-runner activity log is 2.5, read through an injected ActivityLog;
      # SSE is 2.6, so every read here is pull-based, on page render only.
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

        EM_DASH = "—"

        # Pinned wording (Story 2.4 Dev Notes → Detail page contract). The
        # <strong> markup is intentional HTML, not agent-influenced text, so
        # it is never passed through #esc.
        STUCK_FLAG = " — <strong>stuck: respawn is failing</strong>"

        STALENESS_NOTE = "<p class=\"staleness\">Liveness is observed on the supervisor's ~1 s supervision " \
                          "tick, so a crash can take up to ~1 s to appear here. This latency counts inside " \
                          "the ≤ 2 s freshness budget, not on top of it.</p>"

        # Story 2.5 AC1: a truncated timeline otherwise reads as "the runner
        # did nothing", which is the same class of false negative the
        # note_for :stopped/:exited branches guard against.
        ACTIVITY_NOTE = '<p class="activity-note">Recent activity only — the event buffer is bounded and ' \
                         "does not survive a supervisor restart.</p>"

        # Rack raises out of query parsing for a string that exceeds its
        # depth/count limits, carries a bad encoding, or mixes a scalar and an
        # array under one key (?id=1&id[]=2) — the id arrives on a path a
        # client controls entirely (AC11), so every one of those is a 404, not
        # a 500. Rack::BadRequest is the shared ancestor of the whole family;
        # enumerating the leaf classes is what let ParameterTypeError through.
        PARAM_ERRORS = [Rack::BadRequest].freeze

        def initialize(fleet:, activity_log:)
          @fleet = fleet
          @activity_log = activity_log
        end

        def call(env)
          request = Rack::Request.new(env)

          case request.path_info
          # HEAD is how most liveness probes ask; the middleware lets it through
          # on this path for the same reason.
          when "/healthz" then probe(request)
          when "/"        then request.get? ? home(env[Auth::SESSION_ENV_KEY]) : not_found
          when "/entity"  then request.get? ? entity_detail(request, env[Auth::SESSION_ENV_KEY]) : not_found
          else                 not_found
          end
        rescue StandardError => e
          Log.error("[Console] render failed for #{request&.path_info.inspect}: #{e.class}: #{e.message}")
          [500, TEXT_HEADERS.dup, ["internal error"]]
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
          [200, HTML_HEADERS.dup, [layout(session, fleet_html)]]
        end

        # GET /entity?id=<entity id>. A query parameter, not a path segment —
        # Rack::Request#GET decodes reliably where PATH_INFO decoding is
        # server-dependent (Routing contract). Unknown/blank/missing id, or a
        # malformed query string, all fall through to the same #not_found:
        # fixed body, no echo of the attacker-controlled id (AC11).
        def entity_detail(request, session)
          id = entity_id_param(request)
          return not_found unless id

          entry = @fleet.find(id)
          return not_found unless entry

          [200, HTML_HEADERS.dup, [layout(session, entity_page(entry))]]
        end

        # #GET, not #params: the Routing contract is one exact path and one
        # decoded query parameter, and #params would also merge a form-encoded
        # request body — so a GET whose visible URL says one id could render
        # another.
        def entity_id_param(request)
          id = request.GET["id"]
          id.nil? || id.empty? ? nil : id
        rescue *PARAM_ERRORS
          nil
        end

        def not_found
          [404, TEXT_HEADERS.dup, ["not found"]]
        end

        # Shared chrome for every authenticated page (doctype, h1, signed-in-as
        # line, CSRF logout form) — extracted so /entity carries the same chrome
        # as / without a second copy of it. AD-7: every interpolated value is
        # escaped. The username comes from GitLab, entity/workflow names from
        # operator-authored config — not agent-influenced today, but 2.4/2.5 put
        # genuinely agent-influenced values (work-item keys) into this same
        # page, so it escapes by habit rather than by threat model.
        def layout(session, content)
          username = session&.username.to_s
          csrf_token = session&.csrf_token.to_s

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
            #{content}
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
            <tr><td>#{entity_link(entry)}</td><td>#{esc(entry.kind)}</td><td>#{liveness_cell(entry.liveness)}</td><td>#{esc(note_for(entry.status))}</td><td>#{restart_placeholder}</td></tr>
          HTML
        end

        # Href construction, both steps, in this order (Routing contract):
        # Rack::Utils.escape is form encoding, the correct pair for
        # Rack::Request#params; #esc then makes the result a safe attribute
        # value. Skipping the first step breaks any id containing & or #;
        # skipping the second is an XSS hole.
        def entity_link(entry)
          href = esc("/entity?id=#{Rack::Utils.escape(entry.id)}")
          %(<a href="#{href}">#{esc(entry.name)}</a>)
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

        # Detail page contract (Story 2.4 Dev Notes). Conditional rows are
        # omitted entirely, never rendered empty — Restarting-for only when
        # liveness is :restarting (AC4), Work item/Attempt only when a
        # snapshot actually carries one (AC6/AC9: a crashed/exited/stopped
        # snapshot has no work_item field at all, and neither does a
        # messenger/reactor snapshot — the same absence check satisfies both).
        def entity_page(entry)
          <<~HTML
            <p><a href="/">&larr; Fleet</a></p>
            <h2>#{esc(entry.name)}</h2>
            <table>
            <tr><th>Workflow</th><td>#{esc(entry.workflow || EM_DASH)}</td></tr>
            <tr><th>Kind</th><td>#{esc(entry.kind)}</td></tr>
            <tr><th>Liveness</th><td>#{liveness_cell(entry.liveness)}</td></tr>
            <tr><th>Activity</th><td>#{esc(entry.status || EM_DASH)}</td></tr>
            <tr><th>Generation</th><td>#{esc(generation_cell(entry.generation))}</td></tr>
            #{restarting_row(entry)}#{work_item_rows(entry)}<tr><th>State published</th><td>#{esc(entry.observed_at || "never")}</td></tr>
            </table>
            #{note_paragraph(entry.status)}<p>#{restart_placeholder}</p>
            #{STALENESS_NOTE}
            #{activity_section(entry)}
          HTML
        end

        def generation_cell(generation)
          return EM_DASH if generation.nil?

          "#{generation} (#{generation - 1} restart(s))"
        end

        # AC4: the current generation and time-in-restarting, so the operator
        # can distinguish a healthy respawn from a crash-loop where a respawn
        # attempt has failed silently. Not escaped: seconds is our own integer
        # and STUCK_FLAG is a static string carrying intentional <strong>
        # markup, neither is agent-influenced.
        def restarting_row(entry)
          return "" unless entry.liveness == :restarting

          text = "#{entry.seconds_since_published}s"
          text += STUCK_FLAG if entry.stuck_restarting
          "<tr><th>Restarting for</th><td>#{text}</td></tr>\n"
        end

        def work_item_rows(entry)
          return "" unless entry.kind == :runner && entry.work_item

          <<~HTML
            <tr><th>Work item</th><td>#{esc(entry.work_item)}</td></tr>
            <tr><th>Attempt</th><td>#{esc(entry.attempt)}</td></tr>
          HTML
        end

        def note_paragraph(status)
          note = note_for(status)
          return "" if note.empty?

          "<p>#{esc(note)}</p>\n"
        end

        # AC1/AC8: every entity kind gets this section — a messenger or the
        # reactor renders restart-only rows, and a runner with no events yet
        # renders the empty state, never a missing heading (AC8).
        def activity_section(entry)
          events = @activity_log.recent(entry.id)
          heading = "<h3>Recent activity (up to #{@activity_log.limit} events)</h3>"
          body = events.empty? ? "<p>No activity recorded.</p>" : activity_table(events)

          "#{heading}\n#{body}#{ACTIVITY_NOTE}\n"
        end

        def activity_table(events)
          rows = events.map { |event| activity_row(event) }.join
          <<~HTML
            <table>
            <tr><th>When</th><th>Gen</th><th>Event</th><th>Work item</th><th>Attempt</th><th>Detail</th></tr>
            #{rows}</table>
          HTML
        end

        def activity_row(event)
          <<~HTML
            <tr><td>#{esc(event.at || EM_DASH)}</td><td>#{esc(event.generation || EM_DASH)}</td><td>#{esc(event.type || EM_DASH)}</td><td>#{esc(event.work_item || EM_DASH)}</td><td>#{esc(event.attempt || EM_DASH)}</td><td>#{esc(activity_detail(event))}</td></tr>
          HTML
        end

        # Detail cell contract (Story 2.5 Dev Notes): a finished row's reason
        # verbatim, a restart row's actor set joined, and an em dash for
        # anything else — including a record shape this app does not know,
        # never dropped and never raised on.
        def activity_detail(event)
          case event.type
          when :finished then event.reason || EM_DASH
          when :restart
            actors = Array(event.actor)
            actors.empty? ? EM_DASH : "actor: #{actors.join(', ')}"
          else EM_DASH
          end
        end

        def esc(value)
          Rack::Utils.escape_html(value.to_s)
        end
      end
    end
  end
end
