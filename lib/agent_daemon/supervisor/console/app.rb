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
        ELLIPSIS = "…"

        # Characters of an operator's `description:` that the fleet page shows
        # under a name. Long enough for a sentence, short enough that a card
        # keeps its shape in the narrowest grid column; the entity page renders
        # the description in full, so nothing is lost, only deferred.
        SUMMARY_LIMIT = 120

        # `support:` keys in the order the entity page renders them, with their
        # labels. Config validates the vocabulary (Config::SUPPORT_KEYS); this
        # is the presentation half — a key absent from the config renders no row
        # at all rather than an empty one.
        SUPPORT_LABELS = [
          ["owner", "Owner"],
          ["runbook", "Runbook"],
          ["on_failure", "If it breaks"]
        ].freeze

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

        # Story 3.5 DR4/AC4: no run has been selected for this entity at all.
        # Carries a class so the client can retract it the moment a run does
        # start streaming — without one, the page reads "No run output
        # captured." above a live, filling terminal until the next full load.
        TERMINAL_EMPTY_NOTE = '<p class="terminal-empty">No run output captured.</p>'

        # DR4: a selected run that has not printed anything yet — distinct
        # wording from TERMINAL_EMPTY_NOTE so an operator can tell "no run
        # selected" from "run running silently".
        TERMINAL_NO_OUTPUT_YET = "(no output yet)"

        # Story 3.6 Task 6: a dead entity whose runner thread never reached the
        # backend's ensure leaves `finished: false` forever, so the page would
        # otherwise read `Liveness: dead` and `Running` at once.
        TERMINAL_DEAD_LABEL = "Not running — the entity is dead with no recorded run outcome"

        # The client trims its own record window well below what the server
        # retains, so it needs wording of its own — TERMINAL_TRUNCATED_NOTE
        # blames the server buffer, which is not what happened here.
        TERMINAL_CLIENT_TRUNCATED_NOTE = "Earlier output is not shown — this page keeps the most recent lines only."

        # DR4's fourth row: the backend aborted before Sinks::Bundle#end_output_run
        # was ever given a reason (lib/agent_daemon/sinks.rb:71-73). reason.nil?
        # must never be read as "still running" — `finished` does that job.
        TERMINAL_NO_REASON_LABEL = "Finished — run ended without a recorded reason"

        # DR4: truncation is sticky for the run's lifetime and rendered
        # whenever it is true, independent of the finished/running state.
        # The text is its own constant because LIVE_SCRIPT renders the same
        # note client-side; two hand-kept copies of one sentence drift.
        TERMINAL_TRUNCATED_TEXT = "Earlier output was discarded — the per-run output buffer is bounded."
        TERMINAL_TRUNCATED_NOTE = %(<p class="terminal-note">#{TERMINAL_TRUNCATED_TEXT}</p>)

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
          .entity-diagnostics,
          .entity-support { margin: 0 0 1rem; }

          /* One clipped line under a name on the fleet page. */
          .doc-summary {
            margin: -0.5rem 0 0.9rem;
            color: #425466;
            overflow-wrap: anywhere;
          }

          section > .doc-summary { margin: -0.5rem 0 1rem; }

          /* The entity page shows the description verbatim: an operator's line
             breaks are the structure of the text (a short list of steps), and
             this is deliberately not markdown — the text is escaped, never
             parsed. */
          .doc-text {
            margin: 0 0 1rem;
            white-space: pre-wrap;
            overflow-wrap: anywhere;
          }

          /* Same reason as .doc-text: on_failure is usually more than one line. */
          .entity-support dd { white-space: pre-wrap; }

          /* The <dl> is a section's last child, so its bottom margin would
             stack on top of the section's padding. */
          .entity-support:last-child { margin-bottom: 0; }
          .doc-text:last-child { margin-bottom: 0; }

          /* The <dl> is the card's last child, so its own bottom margin would
             stack on top of the card's padding. */
          .activity-timeline li dl { margin: 0; }

          article dl > div,
          .entity-diagnostics > div,
          .entity-support > div,
          .activity-timeline li dl > div {
            display: grid;
            grid-template-columns: minmax(5.5rem, auto) 1fr;
            gap: 0.75rem;
            padding: 0.45rem 0;
            border-top: 1px solid #e1e7ec;
          }

          article dt,
          .entity-diagnostics dt,
          .entity-support dt,
          .activity-timeline dt { color: #425466; font-weight: 600; }

          article dd,
          .entity-diagnostics dd,
          .entity-support dd,
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

          .terminal-state { margin: 0 0 0.75rem; }
          .terminal-note,
          .terminal-client-note { margin: 0 0 0.75rem; color: #425466; }

          /* Story 3.5: the first dark element in the console (DR6). Both
             background and color are set explicitly since :root only
             declares color-scheme: light — nothing here may rely on
             inheriting a dark scheme that does not exist on this page.
             overflow-x is never introduced here (standing prohibition,
             :217-222 above): white-space: pre-wrap + overflow-wrap: anywhere
             instead, so a long unbroken line reflows rather than scrolling
             horizontally. The bounded overflow-y region is the one place a
             tabindex is required for keyboard reachability (WCAG 2.4.7 /
             2.4.11) — everything else on this page is reachable by default. */
          .terminal-panel {
            max-height: 24rem;
            overflow-y: auto;
            padding: 0.75rem;
            border-radius: 0.5rem;
            background: #161b22;
          }

          .terminal-panel:focus-visible {
            outline: 3px solid #b45309;
            outline-offset: -3px;
          }

          .terminal-panel pre {
            margin: 0;
            color: #e6edf3;
            white-space: pre-wrap;
            overflow-wrap: anywhere;
            font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
            font-size: 0.85rem;
            line-height: 1.6;
          }

          .terminal-stream {
            display: inline-block;
            min-width: 2.2rem;
            margin-right: 0.5rem;
            font-weight: 700;
            /* text-indent INHERITS, and an inline-block applies it to its own
               first line box — so .terminal-line's -2.7rem hanging indent was
               shifting these glyphs 2.7rem left of this span, clean out of the
               scroll container. The box stayed where it belonged (hit-testing
               and getBoundingClientRect both looked correct); only the painted
               label vanished, leaving stdout and stderr distinguishable by
               colour alone. Reset it here, not by dropping the hanging indent
               — that indent is what keeps wrapped continuation lines out of
               the gutter column. */
            text-indent: 0;
          }

          .terminal-stream-stdout { color: #7ee787; }
          .terminal-stream-stderr { color: #ff7b72; }

          /* Story 3.6 Task 6 (deferred-work: wrapped-line gutter): a hanging
             indent so a wrapped continuation line lands under the text, not
             under the out/err label, at the 390 px width AC8 targets. */
          .terminal-line {
            padding-left: 2.7rem;
            text-indent: -2.7rem;
          }

          /* AC6: visible text, not colour alone — announced via aria-live so
             a screen-reader user learns new output arrived while scrolled
             up inspecting earlier lines. */
          .terminal-new-output { margin: 0 0 0.75rem; }

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

        # Story 3.6: this story owns LIVE_SCRIPT — pinned since 2.6, frozen
        # again by 3.5 DR8, unfrozen here. Still one IIFE inside the page's
        # one <script> element (inert_body asserts exactly one `<script`).
        #
        # Client-side output state lives in JS variables, never the DOM
        # (Dev Notes Task 4): `terminalState` is null on any page without a
        # `.terminal-panel[data-entity-id]` (messenger/reactor pages, the
        # fleet page) and every output handler below no-ops against null.
        # Once the FIRST output/output_run/output_lagged/output_state event
        # is applied, `terminalState.hasApplied` flips true and the client
        # becomes the panel's sole source of truth (AC11) — a later
        # #console-content refresh re-paints the fresh `<pre>` from
        # `terminalState.records` rather than trusting whatever that fetch's
        # server render happened to show.
        LIVE_SCRIPT = <<~HTML.freeze
          <script>
          (() => {
            let source = null;
            let refreshing = false;
            let dirty = false;
            let terminalState = null;

            const TERMINAL_MAX_CLIENT_RECORDS = 2000;
            const OUTCOMES = ["ok", "failed", "timeout", "killed"];

            function terminalPanel() {
              return document.querySelector(".terminal-panel[data-entity-id]");
            }

            function terminalSection() {
              const heading = document.getElementById("terminal-heading");
              return heading ? heading.closest("section") : null;
            }

            function isPanelAtBottom(panel) {
              return panel.scrollHeight - panel.scrollTop - panel.clientHeight < 4;
            }

            function scrollToBottom(panel) {
              panel.scrollTop = panel.scrollHeight;
            }

            // AC6's accessible indication. A live region only announces when
            // its CONTENTS mutate: registering aria-live on the button itself
            // and then toggling `hidden` — the element already present, its
            // text never changing — is the one arrangement assistive tech
            // reliably stays silent for. So the region is a permanent, empty
            // container and the button is inserted into and removed from it.
            function announceRegion() {
              const section = terminalSection();
              if (!section) return null;
              let region = section.querySelector(".terminal-announce");
              if (!region) {
                region = document.createElement("div");
                region.className = "terminal-announce";
                region.setAttribute("aria-live", "polite");
                section.insertBefore(region, terminalPanel());
              }
              return region;
            }

            function showNewOutputIndicator(panel) {
              const region = announceRegion();
              if (!region || region.firstChild) return;
              const button = document.createElement("button");
              button.type = "button";
              button.className = "terminal-new-output";
              button.textContent = "Newer output below";
              button.addEventListener("click", () => {
                scrollToBottom(panel);
                hideNewOutputIndicator();
              });
              region.appendChild(button);
            }

            function hideNewOutputIndicator() {
              const region = announceRegion();
              if (region) region.textContent = "";
            }

            // `data-*` values are always Strings; every cursor half on the
            // wire is a JSON number. Comparing the two with !== made the
            // first live frame of every page look like a run change, which
            // cleared the panel and reset the dedupe. Normalise on the way in
            // so both halves of every later comparison are Numbers.
            function cursorNumber(value) {
              if (value === undefined || value === null || value === "") return null;
              const parsed = Number(value);
              return Number.isInteger(parsed) && parsed >= 0 ? parsed : null;
            }

            // The server already rendered this run's retained window as
            // .terminal-line nodes. Reading them back is what lets the client
            // become authoritative WITHOUT throwing that output away: it
            // starts holding exactly what is on screen, then appends. Seeded
            // rows carry no seq — the cursor is `data-seq`, and dedupe only
            // ever applies to records that arrived over the stream.
            function seedRecordsFromDom(panel) {
              return Array.prototype.map.call(panel.querySelectorAll(".terminal-line"), (line) => {
                const label = line.querySelector(".terminal-stream");
                const labelText = label ? label.textContent : "";
                return {
                  stream: labelText === "err" ? "stderr" : "stdout",
                  text: line.textContent.slice(labelText.length)
                };
              });
            }

            // Bridges the server-rendered snapshot into a fresh client
            // cursor AND a fresh client record window (AC2). Only called
            // before the client has gone authoritative — see #fetchAndReplace.
            function initTerminalState() {
              const panel = terminalPanel();
              if (!panel) {
                terminalState = null;
                return;
              }
              const section = terminalSection();
              const records = seedRecordsFromDom(panel);
              terminalState = {
                entityId: panel.dataset.entityId,
                generation: cursorNumber(panel.dataset.generation),
                run: cursorNumber(panel.dataset.run),
                lastSeq: cursorNumber(panel.dataset.seq),
                records: records,
                rendered: records.length,
                finished: false,
                reason: null,
                truncated: !!(section && section.querySelector(".terminal-note")),
                clientTruncated: false,
                // The server reconciles "Running" against the entity's
                // liveness; the client has no liveness input, so it reuses
                // that decision instead of hardcoding "Running" (AC7).
                runningLabel: panel.dataset.runningLabel || "Running",
                hasApplied: false
              };
            }

            function boundRecords() {
              const overflow = terminalState.records.length - TERMINAL_MAX_CLIENT_RECORDS;
              if (overflow > 0) {
                terminalState.records.splice(0, overflow);
                terminalState.rendered = Math.max(0, terminalState.rendered - overflow);
                terminalState.clientTruncated = true;
              }
            }

            // AC2/AC10: drops anything at or below the last applied seq —
            // the dedupe that makes a bootstrap-matching first tick, and a
            // resumed reconnect, both no-ops rather than duplicates.
            function applyRecords(generation, run, records) {
              if (!terminalState) return;
              if (terminalState.run !== run || terminalState.generation !== generation) {
                resetRecords(generation, run);
              }
              records.forEach((record) => {
                if (terminalState.lastSeq !== null && record.seq <= terminalState.lastSeq) return;
                terminalState.records.push({ stream: record.stream, text: record.text });
                terminalState.lastSeq = record.seq;
              });
              boundRecords();
              terminalState.hasApplied = true;
            }

            function resetRecords(generation, run) {
              terminalState.generation = generation;
              terminalState.run = run;
              terminalState.records = [];
              terminalState.rendered = 0;
              terminalState.lastSeq = 0;
              terminalState.clientTruncated = false;
            }

            // AC8/AC9: output_run and output_lagged both replace wholesale
            // rather than append. `rendered = 0` is what forces the next
            // render to repaint instead of appending.
            function replaceRecords(generation, run, records) {
              if (!terminalState) return;
              resetRecords(generation, run);
              const kept = records.slice(-TERMINAL_MAX_CLIENT_RECORDS);
              terminalState.clientTruncated = kept.length < records.length;
              terminalState.records = kept.map((record) => ({ stream: record.stream, text: record.text }));
              terminalState.lastSeq = records.length ? records[records.length - 1].seq : 0;
              terminalState.hasApplied = true;
            }

            function applyState(payload) {
              if (!terminalState) return;
              terminalState.finished = payload.finished;
              terminalState.reason = payload.reason;
              terminalState.truncated = payload.truncated;
              terminalState.hasApplied = true;
            }

            // AC4: built with createElement/textContent, no markup parsing —
            // the stream identity stays a visible text label ("out"/"err"),
            // not colour alone.
            function renderTerminalLine(record) {
              const div = document.createElement("div");
              div.className = "terminal-line";
              const span = document.createElement("span");
              const stderr = record.stream === "stderr";
              span.className = "terminal-stream " + (stderr ? "terminal-stream-stderr" : "terminal-stream-stdout");
              span.textContent = stderr ? "err" : "out";
              div.appendChild(span);
              div.appendChild(document.createTextNode(record.text));
              return div;
            }

            function renderNote(section, before, className, wanted, text) {
              let noteEl = section.querySelector("." + className);
              if (wanted) {
                if (!noteEl) {
                  noteEl = document.createElement("p");
                  noteEl.className = className;
                  section.insertBefore(noteEl, before);
                }
                noteEl.textContent = text;
              } else if (noteEl) {
                noteEl.remove();
              }
            }

            function renderTerminalState(panel) {
              const section = terminalSection();
              if (!section) return;

              // The page may have loaded before this entity had ever run, in
              // which case the server rendered "No run output captured." A
              // run is streaming now, so that note is simply false; without
              // removing it the page states both at once until a full reload.
              const emptyNote = section.querySelector(".terminal-empty");
              if (emptyNote) emptyNote.remove();

              let stateEl = section.querySelector(".terminal-state");
              if (!stateEl) {
                stateEl = document.createElement("p");
                stateEl.className = "terminal-state";
                section.insertBefore(stateEl, panel);
              }
              stateEl.textContent = "";
              if (!terminalState.finished) {
                // The server's liveness-reconciled wording, not a hardcoded
                // "Running" — see data-running-label.
                stateEl.textContent = terminalState.runningLabel;
              } else if (!terminalState.reason) {
                stateEl.textContent = "#{TERMINAL_NO_REASON_LABEL}";
              } else {
                stateEl.appendChild(document.createTextNode("Finished — "));
                const span = document.createElement("span");
                const outcome = OUTCOMES.includes(terminalState.reason) ? terminalState.reason : "unknown";
                span.className = "outcome outcome-" + outcome;
                span.textContent = terminalState.reason;
                stateEl.appendChild(span);
              }

              renderNote(section, stateEl, "terminal-note", terminalState.truncated,
                         "#{TERMINAL_TRUNCATED_TEXT}");
              // Distinct from the server note above: this one is about what
              // THIS PAGE dropped, and the two can be true independently.
              renderNote(section, stateEl, "terminal-client-note", terminalState.clientTruncated,
                         "#{TERMINAL_CLIENT_TRUNCATED_NOTE}");
            }

            // AC5/AC6: autoscroll only when already at the bottom; otherwise
            // leave the scroll position alone and surface the indicator.
            // `stickToBottom`, when given, overrides the live scroll-position
            // read — #fetchAndReplace uses this since the freshly replaced
            // panel always starts at scrollTop 0, which is not "at bottom"
            // for any prior scroll state.
            function renderTerminalPanel(stickToBottom) {
              const panel = terminalPanel();
              if (!panel || !terminalState || !terminalState.hasApplied) return;
              const pre = panel.querySelector("pre");
              if (!pre) return;

              const atBottom = typeof stickToBottom === "boolean" ? stickToBottom : isPanelAtBottom(panel);

              // Append-only in the steady state. The previous full teardown
              // (`pre.textContent = ""` then re-create every node) had two
              // costs: it destroyed any text the operator had selected, four
              // times a second, and it rebuilt up to TERMINAL_MAX_CLIENT_RECORDS
              // nodes per frame. `rendered` counts what is already in the DOM
              // and is reset to 0 only by the paths that genuinely replace
              // the window — run change, lag, and #console-content refresh.
              if (terminalState.rendered === 0) pre.textContent = "";

              if (terminalState.records.length === 0) {
                pre.textContent = "#{TERMINAL_NO_OUTPUT_YET}";
              } else {
                const fragment = document.createDocumentFragment();
                terminalState.records.slice(terminalState.rendered).forEach((record) => {
                  fragment.appendChild(renderTerminalLine(record));
                });
                pre.appendChild(fragment);
              }
              terminalState.rendered = terminalState.records.length;

              renderTerminalState(panel);
              panel.dataset.generation = String(terminalState.generation);
              panel.dataset.run = String(terminalState.run);
              panel.dataset.seq = String(terminalState.lastSeq);

              if (atBottom) {
                scrollToBottom(panel);
                hideNewOutputIndicator();
              } else {
                showNewOutputIndicator(panel);
              }
            }

            // One malformed or truncated frame must not take the panel down
            // for the life of the connection: an uncaught throw inside an
            // EventSource listener kills only that dispatch, silently, and
            // the operator is left watching a frozen panel that still looks
            // live. Skip the bad frame; the next tick re-synchronises.
            function onFrame(es, name, handler) {
              es.addEventListener(name, (event) => {
                let data;
                try {
                  data = JSON.parse(event.data);
                } catch (_) {
                  return;
                }
                if (!data || typeof data !== "object") return;
                handler(data);
                renderTerminalPanel();
              });
            }

            function attachOutputListeners(es) {
              onFrame(es, "output", (data) => {
                applyRecords(data.generation, data.run, data.records || []);
              });
              onFrame(es, "output_run", (data) => {
                replaceRecords(data.generation, data.run, data.records || []);
              });
              onFrame(es, "output_lagged", (data) => {
                replaceRecords(data.generation, data.run, data.records || []);
                // AC9: the window jumped forward. The server's own truncation
                // flag rides a separate output_state frame that is not sent
                // when the flag did not change, so without this the gap can
                // be entirely invisible.
                if (terminalState) terminalState.truncated = true;
              });
              onFrame(es, "output_state", (data) => {
                applyState(data);
              });
            }

            async function fetchAndReplace() {
              const response = await fetch(window.location.href, { credentials: "same-origin" });
              const contentType = response.headers.get("content-type") || "";
              if (!response.ok || !contentType.startsWith("text/html")) return;

              const parsed = new DOMParser().parseFromString(await response.text(), "text/html");
              const replacement = parsed.querySelector("#console-content");
              const current = document.querySelector("#console-content");
              if (!replacement || !current) return;

              // Deferred-work fold-in (3.6 Task 4): replaceWith detaches the
              // focused node and resets scroll on any replaced element, so
              // both are captured here and restored below.
              const focusedId = document.activeElement && document.activeElement.id
                ? document.activeElement.id
                : null;
              const oldPanel = terminalPanel();
              const priorScrollTop = oldPanel ? oldPanel.scrollTop : null;
              const wasAtBottom = oldPanel ? isPanelAtBottom(oldPanel) : true;

              current.replaceWith(replacement);

              if (focusedId) {
                const toFocus = document.getElementById(focusedId);
                if (toFocus) toFocus.focus();
              }

              if (terminalState && terminalState.hasApplied) {
                // AC11: the stream is untouched by this replace; only the
                // panel's markup is repainted from the client's own window,
                // which by now may be ahead of whatever this fetch rendered.
                // `rendered = 0` is what turns the next render into a full
                // repaint instead of an append onto the server's markup.
                terminalState.rendered = 0;
                terminalState.runningLabel =
                  (terminalPanel() && terminalPanel().dataset.runningLabel) || terminalState.runningLabel;
                renderTerminalPanel(wasAtBottom);
                if (!wasAtBottom) {
                  const panel = terminalPanel();
                  if (panel && priorScrollTop !== null) panel.scrollTop = priorScrollTop;
                }
              } else {
                initTerminalState();
                const panel = terminalPanel();
                if (panel && priorScrollTop !== null) {
                  panel.scrollTop = wasAtBottom ? panel.scrollHeight : priorScrollTop;
                }
              }
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

            // The bootstrap cursor comes from the current panel's data
            // attributes unless the client has already gone authoritative
            // (a bfcache-restore reconnect, Story 3.6 AC16), in which case
            // its own tracked cursor is more current than the frozen DOM.
            function buildEventsUrl() {
              const panel = terminalPanel();
              if (!panel) return "/events";

              const params = new URLSearchParams();
              params.set("id", panel.dataset.entityId);
              // All three or none — the server discards a partial cursor.
              if (terminalState && terminalState.hasApplied && terminalState.generation !== null) {
                params.set("gen", String(terminalState.generation));
                params.set("run", String(terminalState.run));
                params.set("seq", String(terminalState.lastSeq));
              } else if (panel.dataset.generation !== undefined && panel.dataset.run !== undefined) {
                params.set("gen", panel.dataset.generation);
                params.set("run", panel.dataset.run);
                params.set("seq", panel.dataset.seq || "0");
              }
              return "/events?" + params.toString();
            }

            function connect() {
              if (source) return;
              source = new EventSource(buildEventsUrl());
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
              attachOutputListeners(source);
            }

            initTerminalState();
            // AC5: a terminal opens at its newest line. Without this a panel
            // taller than its max-height loads at scrollTop 0, which reads as
            // "the operator scrolled up" — so autoscroll never engages and
            // the "newer output below" indicator appears immediately on a
            // page the operator has not touched.
            (() => {
              const panel = terminalPanel();
              if (panel) scrollToBottom(panel);
            })();
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

        # Distinguishes "Rack could not parse this query string" from "no id
        # was supplied" — /events needs to answer 404 to the first and a
        # fleet-wide stream to the second (AC14).
        MALFORMED_PARAM = :malformed_param

        NO_CURSOR = [nil, nil, nil].freeze
        CURSOR_MAX_DIGITS = 19

        def initialize(fleet:, activity_log:, live_updates:, output_buffers:)
          @fleet = fleet
          @activity_log = activity_log
          @live_updates = live_updates
          @output_buffers = output_buffers
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
          # Missing and malformed are both 404 here; only /events distinguishes them.
          return not_found unless id.is_a?(String)

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
        # Story 3.6 AC1/AC2/AC14: `id` is optional (the fleet page's stream
        # carries none, unchanged behavior). When present it must resolve to
        # a runner — a messenger/reactor has no output buffer — or this
        # returns the same fixed non-disclosing 404 /entity uses, BEFORE the
        # hijack, so a malformed/unknown/non-runner id never reaches
        # LiveUpdates. `run`/`seq` bootstrap the output cursor (AC2); a
        # reconnect's `Last-Event-ID` header takes priority (AC10).
        def events(request, env)
          return [405, TEXT_HEADERS.dup, request.head? ? [] : ["method not allowed"]] unless request.get?

          authorized = env[Auth::AUTHORIZATION_ENV_KEY]
          unless env["rack.hijack?"] && authorized.respond_to?(:call)
            return [503, TEXT_HEADERS.dup, ["streaming unavailable"]]
          end

          id = entity_id_param(request)
          # AC14 names FOUR rejects — malformed, missing, unknown, non-runner
          # — but only "missing" may fall through to the fleet-wide stream. A
          # query string Rack refuses to parse (`?id=1&id[]=2`) is malformed,
          # not missing, so it must 404 exactly as /entity does rather than
          # silently serving a cursor-less stream that never emits output.
          return not_found if id == MALFORMED_PARAM

          entity_id = nil
          if id
            entry = @fleet.find(id)
            return not_found unless entry && entry.kind == :runner && entry.entity_id

            entity_id = entry.entity_id
          end

          after_generation, after_run_id, after_seq = output_cursor(request, env)

          headers = {
            "content-type" => "text/event-stream; charset=utf-8",
            "cache-control" => "no-cache, no-store",
            "x-accel-buffering" => "no",
            "rack.hijack" => lambda { |io|
              @live_updates.stream(io, authorized: authorized, entity_id: entity_id,
                                    after_generation: after_generation,
                                    after_run_id: after_run_id, after_seq: after_seq)
            }
          }
          [200, headers, []]
        end

        # `Last-Event-ID` (reconnect, AC10) wins over the `gen`/`run`/`seq`
        # query params rendered into the page at load (AC2); either missing,
        # or malformed, degrades to no cursor (full window on first tick) —
        # never a 500 on the Puma thread from OutputBuffers' ArgumentError.
        # Every half is coerced to Integer, matching the type every in-tree
        # producer stamps (Backend::Base's `@run_seq += 1`): a String left
        # over from an un-coerced query param would never `==` that Integer,
        # so every reconnect would misread as a run change.
        def output_cursor(request, env)
          header = env["HTTP_LAST_EVENT_ID"]
          if header.is_a?(String) && !header.empty?
            # Splat-free: a header with fewer than three fields ("1:1", "7")
            # must degrade to no cursor, not raise ArgumentError out of the
            # Puma thread on a value a client controls entirely.
            parts = header.split(":", 3)
            return parse_cursor(parts[0], parts[1], parts[2])
          end

          get = request.GET
          parse_cursor(get["gen"], get["run"], get["seq"])
        rescue *PARAM_ERRORS
          NO_CURSOR
        end

        # All three or none: OutputBuffers raises ArgumentError on a partial
        # cursor, and #emit_output treats a nil generation as "do not check
        # for a respawn", so a half-parsed triple must degrade to no cursor
        # rather than to a plausible-looking one.
        def parse_cursor(generation, run, seq)
          values = [generation, run, seq].map { |value| cursor_integer(value) }
          values.any?(&:nil?) ? NO_CURSOR : values
        end

        # Integer() is deliberately lenient: it accepts a leading sign, `0x`
        # and `0` radix prefixes, and `_` separators. `seq=-1` is the one that
        # bites — OutputBuffers reads any seq below `head_seq - 1` as a lagged
        # cursor, so a negative seq is an on-demand full-window replay for any
        # authenticated client. Base 10, non-negative, and length-bounded so a
        # header-sized digit string cannot make a Bignum on the Puma thread.
        def cursor_integer(value)
          return nil unless value.is_a?(String)
          return nil if value.empty? || value.length > CURSOR_MAX_DIGITS

          parsed = Integer(value, 10)
          parsed.negative? ? nil : parsed
        rescue ArgumentError, TypeError
          nil
        end

        # #GET, not #params: the Routing contract is one exact path and one
        # decoded query parameter, and #params would also merge a form-encoded
        # request body — so a GET whose visible URL says one id could render
        # another. A query string Rack refuses outright is reported as
        # MALFORMED_PARAM rather than nil, because /events (unlike /entity)
        # gives nil a legitimate meaning: the fleet page's id-less stream.
        def entity_id_param(request)
          id = request.GET["id"]
          id.nil? || id.empty? ? nil : id
        rescue *PARAM_ERRORS
          MALFORMED_PARAM
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
                                  label: "Entities in workflow #{name}",
                                  doc: @fleet.workflow_doc(name))
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
        def entity_group(name, entries, heading_id:, label:, doc: nil)
          cards = entries.map { |entry| entity_card(entry) }.join
          <<~HTML
            <section aria-labelledby="#{heading_id}">
            <h2 id="#{heading_id}">#{esc(name)}</h2>
            #{doc_summary(doc)}<ul aria-label="#{esc(label)}" role="list">
            #{cards}</ul>
            </section>
          HTML
        end

        # The fleet page is a scan surface, so a Doc contributes exactly one
        # muted line here: its description's first line, clipped. The full text
        # and the support block live on the entity page — see doc_section.
        # Returns "" (not an empty <p>) when there is nothing to say, which is
        # also what every doc-less config renders.
        def doc_summary(doc)
          summary = summarize(doc&.description)
          return "" unless summary

          %(<p class="doc-summary">#{esc(summary)}</p>\n)
        end

        def summarize(description)
          line = description.to_s.lines.map(&:strip).find { |candidate| !candidate.empty? }
          return nil unless line

          line.length > SUMMARY_LIMIT ? "#{line[0, SUMMARY_LIMIT].rstrip}#{ELLIPSIS}" : line
        end

        def entity_card(entry)
          note = note_for(entry.status)
          note = EM_DASH if note.empty?

          <<~HTML
            <li><article>
            <h3>#{entity_link(entry)}</h3>
            #{doc_summary(entry.doc)}<dl>
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
            #{doc_sections(entry)}#{activity_section(entry)}
            #{terminal_section(entry)}
          HTML
        end

        # Two independent sections, either of which may be absent: what this
        # single piece of work is, and what the workflow around it is. They are
        # separate because they come from different places in the config and a
        # workflow's runbook is the fallback when a runner has none of its own.
        # Config-time text only — nothing here reflects runtime state, so it
        # renders identically on every refresh.
        def doc_sections(entry)
          own = doc_section(entry.doc, heading_id: "entity-doc-heading", title: "What this does")
          workflow_doc = entry.workflow && @fleet.workflow_doc(entry.workflow)
          around = doc_section(workflow_doc, heading_id: "workflow-doc-heading",
                                title: "About workflow #{entry.workflow}")
          "#{own}#{around}"
        end

        def doc_section(doc, heading_id:, title:)
          return "" unless doc

          description = doc.description ? %(<p class="doc-text">#{esc(doc.description)}</p>\n) : ""
          rows = support_rows(doc.support)
          support = rows.empty? ? "" : %(<dl class="entity-support">\n#{rows}\n</dl>\n)

          <<~HTML
            <section aria-labelledby="#{heading_id}">
            <h2 id="#{heading_id}">#{esc(title)}</h2>
            #{description}#{support}</section>
          HTML
        end

        def support_rows(support)
          return "" unless support

          SUPPORT_LABELS.filter_map do |key, label|
            value = support[key]
            next unless value.is_a?(String) && !value.strip.empty?

            %(<div><dt>#{label}</dt><dd>#{support_value(key, value)}</dd></div>)
          end.join("\n")
        end

        # Config already rejects a non-http(s) runbook; the scheme is checked
        # again here because this is the line that turns operator text into an
        # href, and a link element must never be built on a validation done
        # somewhere else. A URL that fails the check renders as plain text.
        def support_value(key, value)
          text = value.strip
          unless key == "runbook" && text.start_with?("http://", "https://")
            return esc(text)
          end

          %(<a href="#{esc(text)}" rel="noopener noreferrer">#{esc(text)}</a>)
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

        # Story 3.5 AC1-AC7/DR3-DR5: the dark terminal panel showing the
        # currently retained output of a runner's current or most recent run.
        # AD-13: only :runner carries run semantics — a messenger/reactor has
        # no agent process, so AC6 omits the whole section rather than
        # rendering it with an empty state (unlike activity_section, which
        # renders an empty state for every kind).
        #
        # DR8, known limitation: output records deliberately do NOT travel the
        # lifecycle EventBus (3.3 DR7), and LiveUpdates watches only that bus
        # and the StateRegistry revision — so NEW OUTPUT LINES ALONE DO NOT
        # TRIGGER AN SSE REFRESH. The panel re-renders when some lifecycle
        # event or state change happens to fire one; continuous output
        # streaming is Story 3.6's whole job, not a bug to fix here.
        #
        # Heading is <h2>, not DR3's <h3>: DR3 justified <h3> with "the page's
        # <h2> is the entity name", but activity_section also emits an <h2>
        # (:770), so the three sibling sections must share one level or the
        # outline claims this one is nested inside Recent activity. It also
        # makes the heading match the existing `section h2` rule (:148) — an
        # <h3> here matched neither that nor `article h3` (:186).
        #
        # Only the scroll container is a named region: a <section> with an
        # accessible name IS a region landmark, so naming both it and DR6's
        # inner role="region" produced two nested landmarks called "Run
        # output". DR6's tab stop needs the name; the wrapper does not.
        # `data-entity-id` (entry.id — the same URL-safe display key
        # /entity?id=… and now /events?id=… both key on, NOT the raw
        # entity_id struct), `data-run`/`data-seq` (the bootstrap cursor,
        # Story 3.6 AC2/Task 3) are the only bridge between this
        # server-rendered snapshot and the client's live cursor. Both cursor
        # attributes are present together or not at all — a started run
        # with zero output (tail_seq nil) still renders `data-seq="0"`, the
        # same placeholder #emit_output uses server-side, so the client never
        # has to special-case "run known, no seq yet".
        def terminal_section(entry)
          return "" unless entry.kind == :runner

          snapshot = @output_buffers.snapshot(entry.entity_id)

          <<~HTML
            <section>
            <h2 id="terminal-heading">Run output</h2>
            #{terminal_notes(snapshot, entry.liveness)}
            <div class="terminal-panel" id="terminal-panel"#{panel_scroll_attrs(snapshot)}
                 data-entity-id="#{esc(entry.id)}"
                 data-running-label="#{esc(terminal_running_label(snapshot, entry.liveness))}"#{cursor_attrs(snapshot)}>
            <pre>#{terminal_body(snapshot)}</pre>
            </div>
            </section>
          HTML
        end

        # The panel keeps its `id` unconditionally — it is what
        # #fetchAndReplace's focus restoration keys on, and it is also the
        # only element the client needs to find once a run starts on a page
        # that loaded empty.
        #
        # A scroll region with nothing to scroll is not a region: for an
        # :empty snapshot the panel renders no tabindex and no role, so a
        # keyboard user does not collect a tab stop onto an empty box
        # announced as "Run output" (Story 3.5 rendered no panel at all here;
        # 3.6 needs the element for its data attributes, not its semantics).
        def panel_scroll_attrs(snapshot)
          return "" if snapshot.status == :empty

          %( tabindex="0" role="region" aria-labelledby="terminal-heading")
        end

        def terminal_notes(snapshot, liveness)
          return TERMINAL_EMPTY_NOTE if snapshot.status == :empty

          "#{snapshot.truncated ? TERMINAL_TRUNCATED_NOTE : ''}#{terminal_state_line(snapshot, liveness)}"
        end

        def terminal_body(snapshot)
          return "" if snapshot.status == :empty

          terminal_lines(snapshot.records)
        end

        def cursor_attrs(snapshot)
          return "" if snapshot.status == :empty

          %( data-generation="#{esc(snapshot.generation)}" data-run="#{esc(snapshot.run_id)}") +
            %( data-seq="#{esc(snapshot.tail_seq || 0)}")
        end

        # DR4's mapping table, exactly: finished: false -> Running; finished:
        # true with a reason -> the existing outcome vocabulary
        # (activity_detail_html's pattern); finished: true with reason: nil ->
        # the no-recorded-reason wording, never mistaken for "still running".
        #
        # Story 3.3 review deferred item, folded in here (3.6 Task 6): a dead
        # entity whose runner thread never reached the backend's ensure
        # leaves `finished: false` forever, so this page would otherwise show
        # `Liveness: dead` three rows up and `Running` here — a
        # self-contradicting page on the one screen that diagnoses crashes.
        # The not-finished label is computed once and also handed to the client
        # as `data-running-label` (Story 3.6 review): the client has no
        # liveness input of its own, so without this it would overwrite the
        # reconciled text with a hardcoded "Running" on the first output_state
        # frame — restoring the exact self-contradiction this reconciliation
        # was added to remove, one tick after page load.
        def terminal_running_label(snapshot, liveness)
          return TERMINAL_DEAD_LABEL if !snapshot.finished && liveness == :dead

          "Running"
        end

        def terminal_state_line(snapshot, liveness)
          return %(<p class="terminal-state">#{terminal_running_label(snapshot, liveness)}</p>) unless snapshot.finished
          return %(<p class="terminal-state">#{TERMINAL_NO_REASON_LABEL}</p>) unless snapshot.reason

          outcome = %i[ok failed timeout killed].include?(snapshot.reason) ? snapshot.reason : :unknown
          %(<p class="terminal-state">Finished — <span class="outcome outcome-#{outcome}">) +
            "#{esc(snapshot.reason)}</span></p>"
        end

        # AC1: ascending seq (the order `records` already arrives in). AC4's
        # :retained + records: [] case (a run started, nothing printed yet)
        # gets its own wording, distinct from the no-run-selected empty state.
        def terminal_lines(records)
          return TERMINAL_NO_OUTPUT_YET if records.empty?

          records.map { |record| terminal_line(record) }.join
        end

        # AC7: `esc` on every byte of record text, no exceptions — the
        # container is a single <pre> (AC7's "preformatted text" is literal),
        # so terminal control characters survive as inert bytes rather than
        # being interpreted. AC1: the stream label is visible TEXT ("out" /
        # "err"), not an aria-label on a bare <span> — Story 3.2's review
        # proved browsers drop that (role="generic" cannot carry an
        # accessible name). Stream is exactly :stdout/:stderr today (DR5:
        # backend/base.rb:118-138 via sinks.rb:57), so the binary branch below
        # is total over the real domain. Anything else would be LABELLED "out"
        # rather than left unlabelled — a deliberate trade: an impossible input
        # is not worth a third branch, and mislabelling beats raising on a Puma
        # thread. Add the unlabelled path only if `stream` ever widens.
        # Story 3.6 Task 6 (deferred-work: wrapped-line gutter): each record
        # is its own block so a hanging indent (.terminal-line in
        # STYLESHEET) keeps a wrapped continuation line off column 0 —
        # otherwise indistinguishable from a new, unlabelled record.
        def terminal_line(record)
          stderr = record.stream == :stderr
          css = stderr ? "terminal-stream-stderr" : "terminal-stream-stdout"
          label = stderr ? "err" : "out"
          %(<div class="terminal-line"><span class="terminal-stream #{css}">#{label}</span>#{esc(record.text)}</div>)
        end

        def esc(value)
          Rack::Utils.escape_html(value.to_s)
        end
      end
    end
  end
end
