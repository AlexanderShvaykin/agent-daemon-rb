# frozen_string_literal: true

module AgentDaemon
  module Supervisor
    # The read-side join that answers "what does the fleet look like right
    # now" (AC1/AC2/AC3/AC5). NOT a supervised entity (AD-13) and NOT under
    # console/ — this is a read-model join Epic 6's exporter will also need,
    # console/ stays the HTTP layer.
    #
    # StateRegistry is populate-on-publish, not an inventory (see its own
    # header): an entity whose first spawn! raised never publishes and is
    # simply absent from it. The roster therefore comes from Master's own
    # entity map — the supervisor's actual boot-time inventory — and the
    # registry is LEFT-JOINED onto it here for state. A rostered entity with
    # no snapshot renders liveness :unknown rather than vanishing.
    #
    # Stdlib only, and it touches nothing but StateRegistry#all: never a
    # runner, a RunnerSupervisor, or a thread (AD-3). #entries is called from
    # Puma request threads while entity threads publish; StateRegistry#all is
    # mutex-guarded and dup's its values, and the roster is frozen at
    # construction and never mutated — that is the whole thread-safety
    # argument. Do not add a second lock, and do not memoise the join (the
    # page must show current state).
    class Fleet
      # One rostered supervised entity, as Master builds it at the same three
      # sites it already writes @entity_ids — the roster can never drift from
      # that set. entity_id must be the identical value @entity_ids holds
      # (the value Sinks::Bundle stamps on every publish and therefore what
      # keys the registry), not a rebuilt copy.
      Rostered = Struct.new(:kind, :workflow, :name, :entity_id, keyword_init: true)

      # A rostered entity joined with its current registry state (or none).
      # The first five members and :id, :generation, :work_item, :attempt,
      # :observed_at are the join itself; :seconds_since_published and
      # :stuck_restarting are derived at read time from the single clock
      # reading #entries takes, so every row describes one instant.
      Entry = Struct.new(:kind, :workflow, :name, :status, :liveness,
                          :id, :generation, :work_item, :attempt,
                          :observed_at, :seconds_since_published, :stuck_restarting,
                          keyword_init: true)

      # Maps a snapshot's raw published :status to a three-way liveness. A
      # status absent from this map (including a nil status, meaning no
      # registry entry at all) is :unknown, never a fall-through to :alive —
      # an unmapped or missing state must read as "I do not know".
      LIVENESS = {
        waiting: :alive, # Runner::Base#run, and after every finished item
        in_progress: :alive, # Runner::Base, mid-item
        running: :alive, # Messenger#run, Mattermost::Reactor#run
        crashed: :restarting, # supervisor-published; auto-restart pending
        # supervisor-published clean terminal exit — NOT auto-restarted
        # (FR3). Correct as `:dead` for Epic 2 only: Epic 1's sole
        # restart-intent producer (:crash_auto) fires on an already-dead
        # thread, so the respawn-intent path (tick_stopping) never publishes
        # :exited today. Epic 4 adds the first producer that queues a
        # restart intent against a LIVE entity and must publish a distinct
        # status when it does, or a runner mid-restart will render `dead`
        # the instant an operator presses Restart (epics.md:499-502).
        exited: :dead,
        stopped: :dead # graceful fleet shutdown
      }.freeze

      # A healthy restart republishes within restart_delay + ~1s (the master
      # tick, master.rb's sleep(1)). Five seconds is that 1s plus four of
      # slack for tick jitter and GC; anything still :crashed past it has had
      # a respawn attempt fail silently (RunnerSupervisor#spawn!'s rescue,
      # which re-arms the deadline and publishes nothing) — see Story 2.4 Dev
      # Notes for the full derivation.
      RESTART_STUCK_MARGIN = 5

      DEFAULT_CLOCK = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

      # The roster is dup'd before freezing: Master hands us the very array it
      # keeps appending to in build_factories, and freezing that object in
      # place would turn a later @roster << into a FrozenError — a boot abort,
      # since nothing on that path rescues.
      #
      # restart_delay: the supervisor's real restart delay, injected rather
      # than imported (see Dev Notes) so this read model never depends on
      # RunnerSupervisor. nil means the stuck-restart flag is unavailable,
      # never "flag everything". clock: injectable so tests advance time
      # instead of sleeping, matching SessionStore's own clock: kwarg.
      def initialize(roster:, state_registry:, restart_delay: nil, clock: DEFAULT_CLOCK)
        @roster = roster.dup.freeze
        @state_registry = state_registry
        @restart_delay = restart_delay
        @clock = clock
      end

      # Roster order, state joined. One registry read per call (#all, not N
      # x #snapshot). Callers that need more than one projection of the same
      # instant must call this once and pass the result to #workflows and
      # #fleet_wide — otherwise the page's rows come from two different reads.
      def entries
        snapshots = @state_registry.all
        now = @clock.call
        @roster.map { |rostered| build_entry(rostered, snapshots[rostered.entity_id], now) }
      end

      # Linear scan: NFR7 caps the fleet at ~20 entities, and the alternative
      # is a second index to keep in sync with the roster.
      def find(id)
        entries.find { |entry| entry.id == id }
      end

      # Config order; each workflow's runners then its messenger. The
      # fleet-wide reactor (workflow: nil) is never grouped under a workflow.
      def workflows(entries = self.entries)
        groups = []
        entries.each do |entry|
          next if entry.kind == :reactor

          group = groups.assoc(entry.workflow)
          unless group
            group = [entry.workflow, []]
            groups << group
          end
          group.last << entry
        end
        groups
      end

      # Entities with no single owning workflow. [] when there is none (no
      # mattermost runner configured anywhere in the fleet).
      def fleet_wide(entries = self.entries)
        entries.select { |entry| entry.kind == :reactor }
      end

      private

      def build_entry(rostered, snapshot, now)
        status = snapshot && snapshot[:status]
        liveness = LIVENESS.fetch(status, :unknown)
        since_published = seconds_since_published(snapshot, now)

        Entry.new(
          kind: rostered.kind,
          workflow: rostered.workflow,
          name: rostered.name,
          status: status,
          liveness: liveness,
          id: entity_id(rostered.entity_id),
          generation: snapshot && snapshot[:generation],
          work_item: snapshot && snapshot[:work_item],
          attempt: snapshot && snapshot[:attempt],
          observed_at: snapshot && snapshot[:observed_at],
          seconds_since_published: since_published,
          stuck_restarting: stuck_restarting?(liveness, since_published)
        )
      end

      # Mirrors RunnerSupervisor#thread_key's fallback: a RunnerIdentity
      # yields its workflow-qualified key, a messenger/reactor entity_id is
      # already the opaque id string.
      def entity_id(entity_id)
        entity_id.respond_to?(:thread_key) ? entity_id.thread_key.to_s : entity_id.to_s
      end

      def seconds_since_published(snapshot, now)
        return nil unless snapshot && snapshot[:observed_monotonic]

        (now - snapshot[:observed_monotonic]).round
      end

      def stuck_restarting?(liveness, seconds_since_published)
        return false unless liveness == :restarting
        return false unless @restart_delay && seconds_since_published

        seconds_since_published > @restart_delay + RESTART_STUCK_MARGIN
      end
    end
  end
end
