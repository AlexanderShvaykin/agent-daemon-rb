# frozen_string_literal: true

require_relative "runner_identity"

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
      # Operator-authored prose about one entity or one workflow: what it is
      # for, and what to do about it. Carried through the read model verbatim —
      # it comes from the config, never from a snapshot, so it is constant for
      # the life of the process and needs no registry read. `support` is the
      # validated Hash from Config (keys in Config::SUPPORT_KEYS) or nil.
      Doc = Struct.new(:description, :support, keyword_init: true) do
        # nil rather than an empty Doc when the config says nothing: the console
        # renders a Doc iff it exists, so absence is the one check it makes.
        def self.build(description:, support:)
          support = nil if support.nil? || support.empty?
          return nil if description.nil? && support.nil?

          new(description: description, support: support).freeze
        end
      end

      # One rostered supervised entity, as Master builds it at the same three
      # sites it already writes @entity_ids — the roster can never drift from
      # that set. entity_id must be the identical value @entity_ids holds
      # (the value Sinks::Bundle stamps on every publish and therefore what
      # keys the registry), not a rebuilt copy. doc is the entity's own Doc, or
      # nil — messenger and reactor rows never carry one.
      Rostered = Struct.new(:kind, :workflow, :name, :entity_id, :doc, keyword_init: true)

      # A rostered entity joined with its current registry state (or none).
      # The first five members and :id, :generation, :work_item, :attempt,
      # :observed_at are the join itself; :seconds_since_published and
      # :stuck_restarting are derived at read time from the single clock
      # reading #entries takes, so every row describes one instant. :entity_id
      # is the raw value Rostered carries — a RunnerIdentity Struct for a
      # runner, an opaque String for messenger/reactor — kept alongside the
      # derived :id (the URL/display key) because OutputBuffers (Story 3.5
      # DR2) keys its buffers by that raw value, not by #id.
      Entry = Struct.new(:kind, :workflow, :name, :status, :liveness,
                          :id, :entity_id, :generation, :work_item, :attempt,
                          :observed_at, :seconds_since_published, :stuck_restarting,
                          :doc,
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
        restart_requested: :restarting, # accepted intent; cooperative stop pending
        # A clean terminal exit remains `:dead`; an accepted restart publishes
        # the distinct `:restart_requested` status above, so it never renders
        # as dead while turnover is pending (epics.md:218).
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
      # workflow_docs: workflow name => Doc, for the workflow-level prose. Kept
      # here rather than copied onto every Entry — it belongs to the group, not
      # to the row, and the console renders it once per workflow heading.
      def initialize(roster:, state_registry:, restart_delay: nil, clock: DEFAULT_CLOCK,
                     workflow_docs: {})
        @roster = roster.dup.freeze
        @state_registry = state_registry
        @restart_delay = restart_delay
        @clock = clock
        @workflow_docs = workflow_docs.dup.freeze
      end

      # The workflow's own Doc, or nil. nil for the fleet-wide reactor's
      # workflow (there is none) and for any workflow whose config says nothing.
      def workflow_doc(name)
        @workflow_docs[name]
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
          entity_id: rostered.entity_id,
          generation: snapshot && snapshot[:generation],
          work_item: snapshot && snapshot[:work_item],
          attempt: snapshot && snapshot[:attempt],
          observed_at: snapshot && snapshot[:observed_at],
          seconds_since_published: since_published,
          stuck_restarting: stuck_restarting?(liveness, since_published),
          doc: rostered.doc
        )
      end

      # Mirrors RunnerSupervisor#thread_key's fallback: a RunnerIdentity
      # yields its workflow-qualified key, a messenger/reactor entity_id is
      # already the opaque id string.
      def entity_id(entity_id)
        RunnerIdentity.key_for(entity_id)
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
