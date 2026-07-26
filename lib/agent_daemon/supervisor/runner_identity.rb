# frozen_string_literal: true

module AgentDaemon
  module Supervisor
    # Composite (workflow, runner) identity for a supervised runner.
    #
    # The standalone daemon keys threads and log tags by runner name only
    # (Daemon#thread_key -> :"runner:#{name}", Runner::Base#log_tag ->
    # "Runner #{name}"). Under the supervisor a runner name is only unique
    # *within* a workflow, so the supervisor keys everything by the
    # (workflow, runner) pair instead. This value object is that composite key;
    # the master (Story 1.4+) consumes it as the actual spawned-thread key and
    # emitted log tag.
    #
    # No `generation` field yet — generation is minted by the per-entity
    # supervisor in Story 1.5.
    RunnerIdentity = Struct.new(:workflow, :runner, keyword_init: true)

    # Reopened (not defined via a `Struct.new do ... end` block) so DELIMITER is
    # a genuine RunnerIdentity constant and resolves lexically inside the
    # instance methods below — a block would scope it to Supervisor instead.
    class RunnerIdentity
      # The single character joining the workflow and runner halves in
      # #thread_key/#log_tag. This is the one place the delimiter is defined;
      # Supervisor::Config forbids it in workflow names (a runner name is core's
      # concern, Story 1.4) so distinct identities can never collide into the
      # same key. Change it here and both the keys and the config guard follow.
      DELIMITER = ":"

      # Workflow-qualified thread key, e.g. :"runner:task-analyst:reviewer".
      # Contrast the core name-only key :"runner:#{name}".
      def thread_key
        :"runner#{DELIMITER}#{workflow}#{DELIMITER}#{runner}"
      end

      # Workflow-qualified log tag, e.g. "task-analyst:reviewer".
      def log_tag
        "#{workflow}#{DELIMITER}#{runner}"
      end

      def to_s
        log_tag
      end

      # The one derivation from an opaque entity_id to the String key the console,
      # the API and the activity log address an entity by. A RunnerIdentity yields
      # its workflow-qualified thread key; a messenger/reactor entity_id is already
      # an opaque String (Master#build_messenger_factory and Master#build_reactor_factory
      # each assign one). Fleet and ActivityLog both call this
      # so a bus record and a roster row can never disagree about who an event
      # belongs to.
      def self.key_for(entity_id)
        entity_id.respond_to?(:thread_key) ? entity_id.thread_key.to_s : entity_id.to_s
      end
    end
  end
end
