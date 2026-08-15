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

    # Per-generation cooperative stop signal. Deliberately NOT
    # AgentDaemon::ShutdownFlag: that one is process-wide and shared by
    # identity, this one is minted per (re)spawn and dies with its generation
    # (AC1). Same protocol on purpose (`#value` / `#set!`), so the entity side
    # can accept either behind one duck type.
    #
    # Mutex-free by design, exactly like ShutdownFlag (daemon.rb): a monotonic
    # one-way boolean is the only lock-free primitive the Spine licenses, and
    # MRI's GIL makes the single-word read/write atomic. Do not add a lock, do
    # not memoise the read, and do not add a way back to false.
    class CancelToken
      def initialize
        @value = false
      end

      def value
        @value
      end

      def set!
        @value = true
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

      attr_reader :state, :generation, :thread, :entity, :cancel_token

      # entity_factory: 1-arg callable (bundle) -> object responding to #run.
      # sinks_factory: 1-arg callable (generation) -> Sinks::Bundle; defaults
      # to a gen-stamped Bundle over Null sinks (output stays plain Null —
      # there is no output record shape to stamp, AD-14 is Epic 3's call).
      # log_level: the owning workflow's resolved ::Logger::Severity int
      # (Master, Story 1.7); nil means no per-tag gate (all severities pass).
      # clock: 0-arg callable -> Time, used for the wall-clock stamps that ride
      # on the intent record and the restart event. Injected rather than read
      # from Time.now directly so tests never have to monkeypatch a core
      # singleton while real entity threads are live (the seam Fleet already
      # uses); the monotonic restart deadline is NOT routed through it.
      def initialize(entity_id, entity_factory:, shutdown_flag:, restart_delay: RESTART_DELAY, sinks_factory: nil,
                     log_level: nil, clock: -> { Time.now.utc })
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
        raise ArgumentError, "clock must respond to #call (entity #{entity_id.inspect})" unless clock.respond_to?(:call)

        @entity_id = entity_id
        @entity_factory = entity_factory
        @shutdown_flag = shutdown_flag
        @restart_delay = restart_delay
        @sinks_factory = sinks_factory || method(:default_sinks_factory)
        @log_level = log_level
        @clock = clock

        @generation = 0
        @state = nil
        @thread = nil
        @entity = nil
        @bundle = nil
        @cancel_token = nil
        @intents = Thread::Queue.new
        @restart_at = nil
        @pending_actors = []
        @pending_requested_at = nil
      end

      # Public because the console POST becomes the second producer on this
      # queue. Works in every state, including terminal :exited, where #tick
      # re-enters the ordinary restart lifecycle.
      def request_restart(actor)
        raise ArgumentError, "actor is required (entity #{@entity_id.inspect})" if actor.nil?

        # Millisecond precision on purpose: coalescing picks the EARLIEST
        # request (AC14) by comparing these strings, and whole-second stamps
        # make two intents inside the same second indistinguishable.
        @intents << { actor: actor, requested_at: @clock.call.iso8601(3) }
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
        cancel_token = CancelToken.new
        entity = @entity_factory.call(bundle)
        key = thread_key

        @generation = generation
        @entity = entity
        @bundle = bundle
        @cancel_token = cancel_token
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
        # A failed replacement owns no generation, so it owns no token either.
        # Dropping the reference matters because the PREVIOUS generation's
        # token is very likely already activated, and Story 4.2's pre-spawn
        # cancel check would read that stale `true` and refuse to respawn.
        @cancel_token = nil
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
        when :exited     then tick_exited
        end
        # A not-yet-spawned supervisor has nothing to drive.
      end

      private

      def tick_running
        if @thread.alive?
          # The shutdown guard mirrors tick_exited's: Master#finalize_supervisors
          # ticks every supervisor once AFTER the flag is set, and accepting an
          # intent there would publish a non-terminal :restart_requested that
          # tick_restarting then refuses to resolve — the entity would render
          # `restarting` (and eventually "restart delayed") forever (AC12).
          if intent_pending? && !@shutdown_flag.value
            @bundle.publish_state(status: :restart_requested)
            @cancel_token.set!
            @state = :stopping
          end
          return
        end

        handle_thread_death
      end

      # A pending intent requests a cooperative stop through this generation's
      # token. The entity-side observer is added separately; this supervisor
      # never force-kills its thread.
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
        # Re-assert the turnover status. The entity's OWN last publish on this
        # generation is a terminal one (`Runner::Base#run` ends on
        # `status: :stopped`, and Messenger/Reactor do the same), StateRegistry
        # accepts equal generations last-write-wins, and the supervisor writes
        # after the thread is confirmed dead — so without this line the console
        # would render `dead` for the whole restart delay, which is exactly the
        # CP-1 failure this story exists to prevent (epics.md:218).
        #
        # This is NOT the per-tick republish Task 2 bans: it fires once, on the
        # :stopping -> :restarting transition, and it re-arms
        # Fleet#seconds_since_published against the delay it now measures.
        @bundle.publish_state(status: :restart_requested)
        accumulate_intents!
        @restart_at = monotonic_now + @restart_delay
        Log.warn("#{log_prefix} entering :restarting (restart deadline in #{@restart_delay}s)")
        @state = :restarting
      end

      def handle_thread_death
        if @thread[:crashed]
          request_restart(:crash_auto)
          @bundle.publish_state(status: :crashed)
          accumulate_intents!
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

      def tick_exited
        return unless intent_pending?
        return if @shutdown_flag.value

        @bundle.publish_state(status: :restart_requested)
        accumulate_intents!
        @restart_at = monotonic_now + @restart_delay
        Log.warn("#{log_prefix} entering :restarting (restart deadline in #{@restart_delay}s)")
        @state = :restarting
      end

      def tick_restarting
        return if monotonic_now < @restart_at
        return if @shutdown_flag.value # no respawn; expiry becomes a no-op

        # Held across a failed spawn so a construction error does not swallow
        # the requesters; spawn! itself re-arms the deadline for the retry.
        accumulate_intents!
        return unless spawn!

        Log.info("#{log_prefix} respawned as generation #{@generation}")
        actors = @pending_actors
        requested_at = @pending_requested_at
        @pending_actors = []
        @pending_requested_at = nil
        @bundle.publish_event(
          type: :restart,
          actor: actors,
          requested_at: requested_at,
          at: @clock.call.iso8601
        )
      end

      def intent_pending?
        !@intents.empty?
      end

      def drain_intents!
        records = []
        loop { records << @intents.pop(true) }
      rescue ThreadError
        actors = records.map { |record| record.fetch(:actor) }.uniq
        requested_at = records.map { |record| record.fetch(:requested_at) }.min
        [actors, requested_at]
      end

      def accumulate_intents!
        actors, requested_at = drain_intents!
        @pending_actors = (@pending_actors + actors).uniq
        @pending_requested_at = [@pending_requested_at, requested_at].compact.min
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
