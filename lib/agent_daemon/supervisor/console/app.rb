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

        # Robot-head favicon, inlined as a data URI so no extra route is needed:
        # a real /favicon.ico would sit behind the default-deny middleware and
        # answer the browser's unauthenticated probe with a login redirect.
        # Percent-encoded where the data-URI grammar demands it ('#' would start
        # a fragment); the mid-tone fill reads on both light and dark tab bars.
        FAVICON = "data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%20viewBox='0%200%2032%2032'%3E" \
                  "%3Crect%20x='6'%20y='12'%20width='20'%20height='16'%20rx='5'%20fill='%234f6bed'/%3E" \
                  "%3Ccircle%20cx='16'%20cy='6'%20r='2'%20fill='%234f6bed'/%3E" \
                  "%3Crect%20x='15'%20y='7'%20width='2'%20height='5'%20fill='%234f6bed'/%3E" \
                  "%3Ccircle%20cx='12'%20cy='19'%20r='2.5'%20fill='%23fff'/%3E" \
                  "%3Ccircle%20cx='20'%20cy='19'%20r='2.5'%20fill='%23fff'/%3E" \
                  "%3Crect%20x='11'%20y='23'%20width='10'%20height='2'%20rx='1'%20fill='%23fff'/%3E" \
                  "%3C/svg%3E"

        STALENESS_NOTE = "<p class=\"staleness\">Liveness is observed on the supervisor's ~1 s supervision " \
                          "tick, so a crash can take up to ~1 s to appear here. This latency counts inside " \
                          "the ≤ 2 s freshness budget, not on top of it.</p>"

        # Story 2.5 AC1: a truncated timeline otherwise reads as "the runner
        # did nothing", which is the same class of false negative the
        # note_for :stopped/:exited branches guard against.
        ACTIVITY_NOTE = '<p class="activity-note">Recent activity only — the event buffer is bounded and ' \
                         "does not survive a supervisor restart.</p>"

        STYLESHEET = <<~CSS.freeze
          :root {
            color-scheme: light;
            font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            color: #172033;
            background: #f3f6f8;
          }

          * { box-sizing: border-box; }

          body {
            margin: 0;
            min-width: 0;
            background: #f3f6f8;
            color: #172033;
            line-height: 1.5;
          }

          a { color: #075ca8; text-underline-offset: 0.16em; }
          a:hover { color: #064779; }

          button {
            min-height: 2.5rem;
            padding: 0.55rem 0.9rem;
            border: 1px solid #31506f;
            border-radius: 0.5rem;
            background: #ffffff;
            color: #172033;
            font: inherit;
          }

          button:disabled {
            border-color: #9da9b5;
            background: #e7ebef;
            color: #52606d;
            cursor: not-allowed;
          }

          a:focus-visible,
          button:focus-visible,
          input:focus-visible {
            outline: 3px solid #b45309;
            outline-offset: 3px;
          }

          .console-header {
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 1.5rem;
            /* The bar is full-bleed but its contents line up with the centred
               #console-content column: half the leftover width, plus that
               column's own padding. */
            padding: 1.25rem calc(max(0px, (100% - 76rem) / 2) + clamp(1rem, 3vw, 2rem));
            border-bottom: 1px solid #cbd5df;
            background: #ffffff;
          }

          .console-header h1,
          .console-header p { margin: 0; }

          .console-session {
            display: flex;
            align-items: center;
            gap: 1rem;
          }

          #console-content {
            width: min(100%, 76rem);
            margin: 0 auto;
            padding: clamp(1rem, 3vw, 2rem);
          }

          #console-content > section {
            padding: clamp(1rem, 2.5vw, 1.5rem);
            border: 1px solid #d4dce4;
            border-radius: 0.75rem;
            background: #ffffff;
            box-shadow: 0 1px 2px rgb(23 32 51 / 8%);
          }

          #console-content > section + section { margin-top: 1.25rem; }
          section h2 { margin: 0 0 1rem; font-size: 1.25rem; }

          .fleet-summary {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(8rem, 1fr));
            gap: 0.75rem;
            margin: 0;
          }

          .fleet-summary > div {
            padding: 0.8rem;
            border-radius: 0.5rem;
            background: #eef3f7;
          }

          .fleet-summary dt { color: #425466; font-size: 0.875rem; }
          .fleet-summary dd { margin: 0.15rem 0 0; font-size: 1.5rem; font-weight: 700; }

          section > ul {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(min(18rem, 100%), 1fr));
            gap: 1rem;
            margin: 0;
            padding: 0;
            list-style: none;
          }

          section > ul > li { min-width: 0; }

          article {
            height: 100%;
            padding: 1rem;
            border: 1px solid #cbd5df;
            border-radius: 0.65rem;
            background: #fbfcfd;
            overflow-wrap: anywhere;
          }

          article h3 { margin: 0 0 0.9rem; font-size: 1.05rem; }
          article dl,
          .entity-diagnostics { margin: 0 0 1rem; }

          /* The <dl> is the card's last child, so its own bottom margin would
             stack on top of the card's padding. */
          .activity-timeline li dl { margin: 0; }

          article dl > div,
          .entity-diagnostics > div,
          .activity-timeline li dl > div {
            display: grid;
            grid-template-columns: minmax(5.5rem, auto) 1fr;
            gap: 0.75rem;
            padding: 0.45rem 0;
            border-top: 1px solid #e1e7ec;
          }

          article dt,
          .entity-diagnostics dt,
          .activity-timeline dt { color: #425466; font-weight: 600; }

          article dd,
          .entity-diagnostics dd,
          .activity-timeline dd { min-width: 0; margin: 0; overflow-wrap: anywhere; }

          .liveness {
            display: inline-block;
            padding: 0.1rem 0.5rem;
            border: 1px solid currentColor;
            border-radius: 999px;
            font-weight: 700;
          }

          .liveness-alive { color: #17633a; background: #e5f5ea; }
          .liveness-restarting { color: #7a4300; background: #fff1d6; }
          .liveness-dead { color: #8a2432; background: #fde8eb; }
          .liveness-unknown { color: #4b5563; background: #eceff2; }

          .status-note { margin: 0.3rem 0 0; color: #425466; }

          .restart-warning {
            padding: 0.75rem;
            border-left: 0.3rem solid #9a5700;
            border-radius: 0.35rem;
            background: #fff1d6;
            color: #5f3600;
          }

          /* Standing prohibition, carried forward from Story 3.1's review: no
             `display: block` on a tabular element, and no `overflow-x` scroll
             container. The first drops the implicit table/row/cell roles in
             Blink and WebKit; the second is not keyboard-reachable without a
             tabindex. Story 3.2 routes around both by making the timeline an
             ordered list that reflows natively — do not reintroduce either. */
          .activity-timeline {
            display: grid;
            gap: 0.9rem;
            margin: 0;
            padding: 0;
            list-style: none;
          }

          .activity-timeline > li {
            min-width: 0;
            padding: 1rem;
            border: 1px solid #cbd5df;
            border-left: 0.3rem solid #52708f;
            border-radius: 0.65rem;
            background: #fbfcfd;
          }

          .generation-boundary {
            margin: 0 0 0.75rem;
            padding-bottom: 0.5rem;
            border-bottom: 2px solid #71869b;
            color: #263f58;
            font-weight: 700;
          }

          .outcome {
            display: inline-block;
            padding: 0.1rem 0.5rem;
            border: 1px solid currentColor;
            border-radius: 999px;
            font-weight: 700;
          }

          .outcome-ok { color: #17633a; background: #e5f5ea; }
          .outcome-failed { color: #8a2432; background: #fde8eb; }
          .outcome-timeout { color: #7a4300; background: #fff1d6; }
          .outcome-killed { color: #3f4650; background: #eceff2; }
          .outcome-unknown { color: #4b5563; background: #eceff2; }

          .staleness,
          .activity-note { color: #425466; }

          @media (max-width: 40rem) {
            .console-header,
            .console-session { align-items: stretch; flex-direction: column; }
            .console-header { padding: 1.25rem 1rem; }
            .console-session { gap: 0.75rem; }
            .console-session button { width: 100%; }
            #console-content { padding: 1rem; }
            #console-content > section { padding: 1rem; }
            .fleet-summary { grid-template-columns: repeat(2, minmax(0, 1fr)); }
            article dl > div,
            .entity-diagnostics > div,
            .activity-timeline li dl > div { grid-template-columns: 1fr; gap: 0.1rem; }
            .activity-timeline > li { padding: 0.8rem; }
          }
        CSS

        LIVE_SCRIPT = <<~HTML.freeze
          <script>
          (() => {
            let source = null;
            let refreshing = false;
            let dirty = false;

            async function fetchAndReplace() {
              const response = await fetch(window.location.href, { credentials: "same-origin" });
              const contentType = response.headers.get("content-type") || "";
              if (!response.ok || !contentType.startsWith("text/html")) return;

              const parsed = new DOMParser().parseFromString(await response.text(), "text/html");
              const replacement = parsed.querySelector("#console-content");
              const current = document.querySelector("#console-content");
              if (replacement && current) current.replaceWith(replacement);
            }

            async function refreshContent() {
              if (refreshing) {
                dirty = true;
                return;
              }

              refreshing = true;
              try {
                do {
                  dirty = false;
                  try { await fetchAndReplace(); } catch (_) {}
                } while (dirty);
              } finally {
                refreshing = false;
              }
            }

            function toLogin() {
              if (source) source.close();
              source = null;
              const returnPath = window.location.pathname + window.location.search;
              const login = new URL("/auth/login", window.location.origin);
              login.searchParams.set("return_to", returnPath);
              window.location.assign(login.pathname + login.search);
            }

            function connect() {
              if (source) return;
              source = new EventSource("/events");
              source.addEventListener("open", refreshContent);
              source.addEventListener("refresh", refreshContent);
              source.addEventListener("authorization_lost", toLogin);
              // A CLOSED EventSource is fatal per the SSE specification: the
              // browser will not reconnect on its own. That is what an expired
              // session looks like once the socket is already down — /events
              // answers with a redirect, not text/event-stream. Without this
              // the page would sit on stale state looking live forever.
              source.addEventListener("error", () => {
                if (source && source.readyState === EventSource.CLOSED) toLogin();
              });
            }

            connect();
            // pagehide also fires when the page enters the back/forward cache,
            // so the listener must stay registered and pageshow must re-open —
            // otherwise pressing Back restores a live-looking page with a
            // closed stream that never updates again.
            window.addEventListener("pagehide", () => {
              if (source) source.close();
              source = null;
            });
            window.addEventListener("pageshow", (event) => {
              if (event.persisted) connect();
            });
          })();
          </script>
        HTML

        # Rack raises out of query parsing for a string that exceeds its
        # depth/count limits, carries a bad encoding, or mixes a scalar and an
        # array under one key (?id=1&id[]=2) — the id arrives on a path a
        # client controls entirely (AC11), so every one of those is a 404, not
        # a 500. Rack::BadRequest is the shared ancestor of the whole family;
        # enumerating the leaf classes is what let ParameterTypeError through.
        PARAM_ERRORS = [Rack::BadRequest].freeze

        def initialize(fleet:, activity_log:, live_updates:)
          @fleet = fleet
          @activity_log = activity_log
          @live_updates = live_updates
        end

        def call(env)
          request = Rack::Request.new(env)

          case request.path_info
          # HEAD is how most liveness probes ask; the middleware lets it through
          # on this path for the same reason.
          when "/healthz" then probe(request)
          when "/"        then page_request?(request) ? home(request, env[Auth::SESSION_ENV_KEY]) : not_found
          when "/entity"  then page_request?(request) ? entity_detail(request, env[Auth::SESSION_ENV_KEY]) : not_found
          when "/events"  then events(request, env)
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
        def home(request, session)
          html(request, layout(session, fleet_html))
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

          html(request, layout(session, entity_page(entry)))
        end

        def page_request?(request)
          request.get? || request.head?
        end

        def html(request, body)
          [200, HTML_HEADERS.dup, request.head? ? [] : [body]]
        end

        # SSE is GET-only, so every other verb is a 405 — bodiless for HEAD,
        # which must carry no body per RFC 9110 exactly as / and /entity do.
        def events(request, env)
          return [405, TEXT_HEADERS.dup, request.head? ? [] : ["method not allowed"]] unless request.get?

          authorized = env[Auth::AUTHORIZATION_ENV_KEY]
          unless env["rack.hijack?"] && authorized.respond_to?(:call)
            return [503, TEXT_HEADERS.dup, ["streaming unavailable"]]
          end

          headers = {
            "content-type" => "text/event-stream; charset=utf-8",
            "cache-control" => "no-cache, no-store",
            "x-accel-buffering" => "no",
            "rack.hijack" => ->(io) { @live_updates.stream(io, authorized: authorized) }
          }
          [200, headers, []]
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
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>agent-daemon console</title>
            <link rel="icon" href="#{FAVICON}">
            <style>
            #{STYLESHEET}</style>
            </head>
            <body>
            <header class="console-header">
            <div>
            <h1>agent-daemon console</h1>
            <p>Signed in as <strong>#{esc(username)}</strong></p>
            </div>
            <div class="console-session">
            <form method="post" action="/auth/logout">
            <input type="hidden" name="_csrf" value="#{esc(csrf_token)}">
            <button type="submit">Log out</button>
            </form>
            </div>
            </header>
            <main id="console-content">
            #{content}</main>
            #{LIVE_SCRIPT}
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

          html = +fleet_summary(entries)
          if workflows.empty? && fleet_wide.empty?
            html << <<~HTML
              <section aria-labelledby="fleet-entities-heading">
              <h2 id="fleet-entities-heading">Supervised entities</h2>
              <p>No supervised entities.</p>
              </section>
            HTML
            return html
          end

          workflows.each_with_index do |(name, group_entries), index|
            html << entity_group(name, group_entries, heading_id: "workflow-#{index}-heading",
                                  label: "Entities in workflow #{name}")
          end
          unless fleet_wide.empty?
            html << entity_group("Fleet-wide", fleet_wide, heading_id: "fleet-wide-heading",
                                  label: "Fleet-wide entities")
          end
          html
        end

        def fleet_summary(entries)
          counts = entries.each_with_object(Hash.new(0)) { |entry, result| result[entry.liveness] += 1 }
          items = [["Total", entries.size], ["Alive", counts[:alive]], ["Restarting", counts[:restarting]],
                   ["Dead", counts[:dead]]]
          items << ["Unknown", counts[:unknown]] if counts[:unknown].positive?
          values = items.map { |label, count| "<div><dt>#{label}</dt><dd>#{count}</dd></div>" }.join("\n")

          <<~HTML
            <section aria-labelledby="fleet-summary-heading">
            <h2 id="fleet-summary-heading">Fleet summary</h2>
            <dl class="fleet-summary">
            #{values}
            </dl>
            </section>
          HTML
        end

        # role="list" is not redundant: `list-style: none` suppresses the
        # implicit list role in Safari/VoiceOver, which would take the group's
        # aria-label and its item count with it — the whole point of labelling
        # the group.
        def entity_group(name, entries, heading_id:, label:)
          cards = entries.map { |entry| entity_card(entry) }.join
          <<~HTML
            <section aria-labelledby="#{heading_id}">
            <h2 id="#{heading_id}">#{esc(name)}</h2>
            <ul aria-label="#{esc(label)}" role="list">
            #{cards}</ul>
            </section>
          HTML
        end

        def entity_card(entry)
          note = note_for(entry.status)
          note = EM_DASH if note.empty?

          <<~HTML
            <li><article>
            <h3>#{entity_link(entry)}</h3>
            <dl>
            <div><dt>Kind</dt><dd>#{esc(entry.kind)}</dd></div>
            <div><dt>Liveness</dt><dd>#{liveness_cell(entry.liveness)}</dd></div>
            <div><dt>Note</dt><dd>#{esc(note)}</dd></div>
            </dl>
            #{restart_placeholder}
            </article></li>
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
            <section aria-labelledby="entity-diagnostics-heading">
            <h2 id="entity-diagnostics-heading">#{esc(entry.name)}</h2>
            <dl class="entity-diagnostics">
            <div><dt>Workflow</dt><dd>#{esc(entry.workflow || EM_DASH)}</dd></div>
            <div><dt>Kind</dt><dd>#{esc(entry.kind)}</dd></div>
            <div><dt>Liveness</dt><dd>#{liveness_cell(entry.liveness)}</dd></div>
            <div><dt>Activity</dt><dd>#{activity_status(entry.status)}</dd></div>
            #{work_item_rows(entry)}#{restarting_row(entry)}<div><dt>Generation</dt><dd>#{esc(generation_cell(entry.generation))}</dd></div>
            <div><dt>State published</dt><dd>#{esc(entry.observed_at || "never")}</dd></div>
            </dl>
            #{restart_delayed_warning(entry)}<p>#{restart_placeholder}</p>
            #{STALENESS_NOTE}
            </section>
            #{activity_section(entry)}
          HTML
        end

        def generation_cell(generation)
          return EM_DASH if generation.nil?

          "#{generation} (#{generation - 1} restart(s))"
        end

        # AC4: the current generation and time-in-restarting, so the operator
        # can distinguish a healthy respawn from a crash-loop where a respawn
        # attempt has failed silently. Seconds is our own integer.
        def restarting_row(entry)
          return "" unless entry.liveness == :restarting

          "<div><dt>Restarting for</dt><dd>#{entry.seconds_since_published}s</dd></div>\n"
        end

        def work_item_rows(entry)
          return "" unless entry.kind == :runner && entry.work_item

          <<~HTML
            <div><dt>Work item</dt><dd>#{esc(entry.work_item)}</dd></div>
            <div><dt>Attempt</dt><dd>#{esc(entry.attempt)}</dd></div>
          HTML
        end

        def activity_status(status)
          note = note_for(status)
          value = esc(status || EM_DASH)
          return value if note.empty?

          %(#{value}<p class="status-note">#{esc(note)}</p>)
        end

        # Guarded on liveness as well as the flag: `Fleet#stuck_restarting?`
        # already refuses to set it outside `:restarting`, but that invariant
        # lives one object away, and the failure mode here would be a warning
        # on an entity with no "Restarting for" row to explain it.
        def restart_delayed_warning(entry)
          return "" unless entry.liveness == :restarting && entry.stuck_restarting

          '<p class="restart-warning"><strong>Restart delayed</strong> — respawn is failing</p>'
        end

        # AC1/AC8: every entity kind gets this section — a messenger or the
        # reactor renders restart-only rows, and a runner with no events yet
        # renders the empty state, never a missing heading (AC8).
        def activity_section(entry)
          events = @activity_log.recent(entry.id)
          body = events.empty? ? "<p>No activity recorded.</p>" : activity_timeline(events)

          <<~HTML
            <section aria-labelledby="activity-heading">
            <h2 id="activity-heading">Recent activity (up to #{esc(@activity_log.limit)} events)</h2>
            #{body}#{ACTIVITY_NOTE}
            </section>
          HTML
        end

        # ActivityLog owns ordering and truncation. The renderer preserves its
        # newest-first sequence verbatim and only marks transitions between
        # adjacent generations. `reversed` keeps the ordinals honest: item one
        # of a newest-first list is the *last* event, not the first.
        def activity_timeline(events)
          items = events.each_with_index.map do |event, index|
            # The sequence is newest-first, so the preceding element is the
            # event that happened *after* this one.
            newer = index.positive? ? events[index - 1] : nil
            activity_item(event, generation_changed: generation_changed?(event, newer))
          end.join

          <<~HTML
            <ol class="activity-timeline" role="list" reversed>
            #{items}</ol>
          HTML
        end

        # A boundary needs two known generations to sit between. An event that
        # carries none is a gap in the record, not a restart, and labelling it
        # "Generation boundary: —" would assert a transition that never happened.
        def generation_changed?(event, newer)
          return false if newer.nil? || event.generation.nil? || newer.generation.nil?

          event.generation != newer.generation
        end

        def activity_item(event, generation_changed:)
          boundary = if generation_changed
                       %(<p class="generation-boundary">Generation boundary: #{esc(event.generation)}</p>\n)
                     else
                       ""
                     end

          <<~HTML
            <li>
            #{boundary}<dl>
            <div><dt>When</dt><dd>#{esc(event.at || EM_DASH)}</dd></div>
            <div><dt>Generation</dt><dd>#{esc(event.generation || EM_DASH)}</dd></div>
            <div><dt>Event</dt><dd>#{esc(event.type || EM_DASH)}</dd></div>
            <div><dt>Work item</dt><dd>#{esc(event.work_item || EM_DASH)}</dd></div>
            <div><dt>Attempt</dt><dd>#{esc(event.attempt || EM_DASH)}</dd></div>
            <div><dt>Detail</dt><dd>#{activity_detail_html(event)}</dd></div>
            </dl>
            </li>
          HTML
        end

        # The badge is presentation over `activity_detail`'s text, never a
        # second source of it — a finished event's visible label is still the
        # reason that method returns. No aria-label: a <span> maps to
        # role="generic", which ARIA forbids from carrying an accessible name,
        # so the label would be dropped by Chrome and Firefox and would
        # *replace* the visible text where it is honoured. The <dt>Detail</dt>
        # already supplies the association, and per AC8 the text carries the
        # meaning while the colour is decoration.
        def activity_detail_html(event)
          detail = activity_detail(event)
          return esc(detail) unless event.type == :finished

          outcome = %i[ok failed timeout killed].include?(event.reason) ? event.reason : :unknown
          %(<span class="outcome outcome-#{outcome}">#{esc(detail)}</span>)
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
