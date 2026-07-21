# frozen_string_literal: true

require "time"

require_relative "../sinks"
require_relative "../log"

module AgentDaemon
  module Supervisor
    # Decorator around a state/event sink that stamps the owning supervisor's
    # generation onto every record. A fresh instance is built per (re)spawn
    # (Task 3/AD-16), so a superseded (old-gen) entity's late publish still
    # carries its own, now-stale generation — the registry's compare-and-set
    # consumer (Epic 2) relies on exactly this.
    class GenerationStamp
      def initialize(generation, inner)
        @generation = generation
        @inner = inner
      end

      def publish(entity_id, record)
        @inner.publish(entity_id, record.merge(generation: @generation))
      end
    end

    # Per-entity supervisor state machine (AD-2). One instance supervises the
    # full spawn/observe/respawn lifecycle of a SINGLE supervised entity —
    # this covers ALL three entity kinds (runner, messenger, reactor), not
    # just runners; the file/class name is mandated by the Spine's source
    # tree, not a scope restriction.
    #
    # `#tick` is the only driver: non-blocking, called ~1/s by the master
    # loop. It never sleeps — a pending restart delay is a recorded deadline
    # (monotonic clock), not a blocking wait, so one entity's crash never
    # stalls another's supervision (AC1/C6, replacing the blocking 60s sleep
    # in Daemon#monitor_threads).
    class RunnerSupervisor
      RESTART_DELAY = 60

      attr_reader :state, :generation, :thread, :entity

      # entity_factory: 1-arg callable (bundle) -> object responding to #run.
      # sinks_factory: 1-arg callable (generation) -> Sinks::Bundle; defaults
      # to a gen-stamped Bundle over Null sinks (output stays plain Null —
      # there is no output record shape to stamp, AD-14 is Epic 3's call).
      # log_level: the owning workflow's resolved ::Logger::Severity int
      # (Master, Story 1.7); nil means no per-tag gate (all severities pass).
      def initialize(entity_id, entity_factory:, shutdown_flag:, restart_delay: RESTART_DELAY, sinks_factory: nil,
                     log_level: nil)
        raise ArgumentError, "entity_id is required" if entity_id.nil?
        unless entity_factory.respond_to?(:call)
          raise ArgumentError, "entity_factory must respond to #call (entity #{entity_id.inspect})"
        end
        unless shutdown_flag.respond_to?(:value)
          raise ArgumentError, "shutdown_flag must respond to #value (entity #{entity_id.inspect})"
        end
        if sinks_factory && !sinks_factory.respond_to?(:call)
          raise ArgumentError, "sinks_factory must respond to #call (entity #{entity_id.inspect})"
        end

        @entity_id = entity_id
        @entity_factory = entity_factory
        @shutdown_flag = shutdown_flag
        @restart_delay = restart_delay
        @sinks_factory = sinks_factory || method(:default_sinks_factory)
        @log_level = log_level

        @generation = 0
        @state = nil
        @thread = nil
        @entity = nil
        @bundle = nil
        @intents = Thread::Queue.new
        @restart_at = nil
        @pending_actors = []
      end

      # Public because Epic 4's console POST becomes the second producer on
      # this queue (E1: the only producer is this supervisor's own
      # crash-auto path in #tick). Works in every state, including :exited —
      # an intent queued against an exited entity is left for Epic 4 to
      # decide how to consume (Task 4).
      def request_restart(actor)
        raise ArgumentError, "actor is required (entity #{@entity_id.inspect})" if actor.nil?

        @intents << { actor: actor }
      end

      # First spawn mints generation 1; every subsequent call (only ever from
      # #tick, on a confirmed-dead thread) increments it. Builds a FRESH
      # bundle so the dying instance's own (old) bundle reference is
      # untouched (AC3). Returns true on success, false if the spawn was
      # refused or the factories raised.
      def spawn!
        # Task 2's at-most-one-live-instance is a checked precondition, not an
        # invariant left to caller discipline: #tick only ever calls this on a
        # confirmed-dead thread, but the method is public for Epic 4.
        if @thread&.alive?
          Log.warn("[#{thread_key}] spawn! refused: generation #{@generation} is still alive")
          return false
        end

        # The factories run on the CALLER's thread, so a raise here would
        # otherwise escape through Master#tick and abort supervision of every
        # other entity. Treat a failed construction exactly like a crash: keep
        # the generation unburned and retry on the normal restart deadline.
        generation = @generation + 1
        bundle = @sinks_factory.call(generation)
        entity = @entity_factory.call(bundle)
        key = thread_key

        @generation = generation
        @entity = entity
        @bundle = bundle
        # Ambient context binds THIS entity's own thread only (the master
        # thread driving #tick never sets it) — the crash rescue below runs
        # inside this same block/thread, so it inherits the tag for free and
        # no longer needs its own manual prefix.
        @thread = Thread.new do
          Thread.current.name = key.to_s
          Log.bind_context(tag: log_tag, generation: generation, level: @log_level)
          entity.run
        rescue => e
          Log.error("Thread crashed: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}")
          Thread.current[:crashed] = true
          Thread.current[:crash_error] = e
        end
        @state = :running
        true
      rescue => e
        Log.error("[#{thread_key}] Spawn failed: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}")
        @restart_at = monotonic_now + @restart_delay
        Log.warn("#{log_prefix} entering :restarting (restart deadline in #{@restart_delay}s)")
        @state = :restarting
        false
      end

      def tick
        case @state
        when :running    then tick_running
        when :stopping   then tick_stopping
        when :restarting then tick_restarting
        end
        # :exited (or not-yet-spawned) is terminal/no-op — nothing to drive.
      end

      private

      def tick_running
        if @thread.alive?
          @state = :stopping if intent_pending?
          return
        end

        handle_thread_death
      end

      # A pending intent only ever moves :running -> :stopping to passively
      # await a death it did not cause (E1: no Thread#kill, no active stop —
      # that is Epic 4).
      def tick_stopping
        return if @thread.alive?

        # A crash here is indistinguishable from :running's and takes the
        # shared path. A CLEAN death, however, must NOT fall through to AC2's
        # terminal :exited: we only got here because a restart intent was
        # queued, and AC4 requires that intent to be honoured. Dropping it
        # would strand Epic 4's manual restart of a healthy entity — a
        # cooperative stop is exactly a clean `run` return.
        return handle_thread_death if @thread[:crashed]

        Log.info("#{log_prefix} exited cleanly")
        @bundle.publish_state(status: :exited)
        @pending_actors = drain_intents!
        @restart_at = monotonic_now + @restart_delay
        Log.warn("#{log_prefix} entering :restarting (restart deadline in #{@restart_delay}s)")
        @state = :restarting
      end

      def handle_thread_death
        if @thread[:crashed]
          request_restart(:crash_auto)
          @bundle.publish_state(status: :crashed)
          @pending_actors = drain_intents!
          @restart_at = monotonic_now + @restart_delay
          Log.warn("#{log_prefix} entering :restarting (restart deadline in #{@restart_delay}s)")
          @state = :restarting
        else
          # AC2: a clean exit is never auto-restarted (manual restart only,
          # Epic 4). This boundary is the supervisor-published :exited status.
          Log.info("#{log_prefix} exited cleanly, terminal")
          @bundle.publish_state(status: :exited)
          @state = :exited
        end
      end

      def tick_restarting
        return if monotonic_now < @restart_at
        return if @shutdown_flag.value # no respawn; expiry becomes a no-op

        # Held across a failed spawn so a construction error does not swallow
        # the requesters; spawn! itself re-arms the deadline for the retry.
        @pending_actors = (@pending_actors + drain_intents!).uniq
        return unless spawn!

        Log.info("#{log_prefix} respawned as generation #{@generation}")
        actors = @pending_actors
        @pending_actors = []
        @bundle.publish_event(type: :restart, actor: actors, at: Time.now.utc.iso8601)
      end

      def intent_pending?
        !@intents.empty?
      end

      def drain_intents!
        actors = []
        loop { actors << @intents.pop(true).fetch(:actor) }
        actors
      rescue ThreadError
        actors
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # RunnerIdentity#thread_key for runners; the entity_id IS the thread key
      # for messenger ("messenger:<workflow>") and reactor ("mattermost_reactor")
      # entities (1.4's Thread-key map) — both are opaque, plain Strings here.
      def thread_key
        @entity_id.respond_to?(:thread_key) ? @entity_id.thread_key : @entity_id
      end

      # RunnerIdentity#log_tag for runners; the entity_id IS the log tag for
      # messenger/reactor entities, same fallback as #thread_key.
      def log_tag
        @entity_id.respond_to?(:log_tag) ? @entity_id.log_tag : @entity_id.to_s
      end

      # Explicit tag+generation formatting for lines emitted on the MASTER
      # thread (#tick and its callees) — that thread never carries the
      # ambient context Log.bind_context sets on the entity's OWN thread, so
      # supervisor-lifecycle lines must format the prefix themselves. Reuses
      # the same formatter ambient tagging uses (Log.tag_prefix) so both
      # paths are format-identical.
      def log_prefix
        Log.tag_prefix(log_tag, @generation)
      end
      # Public so the master thread's shutdown-path lines (Master#wait_for_threads
      # /#finalize_supervisors/#sweep_orphaned_agents) can tag themselves with the
      # same [tag genN] format — they run on the master thread with no ambient
      # context, exactly like the #tick lifecycle lines.
      public :log_prefix

      def default_sinks_factory(generation)
        Sinks::Bundle.new(
          entity_id: @entity_id,
          state: GenerationStamp.new(generation, Sinks::NullState.new),
          event: GenerationStamp.new(generation, Sinks::NullEvent.new)
        )
      end
    end
  end
end
