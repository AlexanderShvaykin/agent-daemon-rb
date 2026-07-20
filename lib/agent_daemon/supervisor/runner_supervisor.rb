# frozen_string_literal: true

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
      def initialize(entity_id, entity_factory:, shutdown_flag:, restart_delay: RESTART_DELAY, sinks_factory: nil)
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
      # untouched (AC3).
      def spawn!
        @generation += 1
        bundle = @sinks_factory.call(@generation)
        entity = @entity_factory.call(bundle)
        key = thread_key

        @entity = entity
        @bundle = bundle
        @thread = Thread.new do
          Thread.current.name = key.to_s
          entity.run
        rescue => e
          Log.error("[#{key}] Thread crashed: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}")
          Thread.current[:crashed] = true
          Thread.current[:crash_error] = e
        end
        @state = :running
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
      # that is Epic 4). Once dead, the outcome is identical to :running's.
      def tick_stopping
        return if @thread.alive?

        handle_thread_death
      end

      def handle_thread_death
        if @thread[:crashed]
          request_restart(:crash_auto)
          @bundle.publish_state(status: :crashed)
          @pending_actors = drain_intents!
          @restart_at = monotonic_now + @restart_delay
          @state = :restarting
        else
          # AC2: a clean exit is never auto-restarted (manual restart only,
          # Epic 4). This boundary is the supervisor-published :exited status.
          @bundle.publish_state(status: :exited)
          @state = :exited
        end
      end

      def tick_restarting
        return if monotonic_now < @restart_at
        return if @shutdown_flag.value # no respawn; expiry becomes a no-op

        # At-most-one live instance holds by construction: :restarting is only
        # entered after handle_thread_death observed @thread already dead.
        actors = (@pending_actors + drain_intents!).uniq
        spawn!
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
