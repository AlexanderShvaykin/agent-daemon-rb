# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "yaml"

# AD-5 lazy-require isolation: required explicitly here, never from the core
# `require "agent_daemon"` graph.
require "agent_daemon/supervisor/state_registry"
require "agent_daemon/supervisor/event_bus"
require "agent_daemon/supervisor/runner_supervisor"
require "agent_daemon/supervisor/master"

# AI-1 (Epic 1 retro): this file exists specifically to drive REAL production
# objects (Runner::File, RunnerSupervisor, Master, Sinks::Bundle,
# GenerationStamp) through the read model, never a re-implementation of the
# code under test. Doubles are reserved for the raising-sink cases and the
# entities' own trivial #run bodies.

# Own copy of test_sinks.rb's harness (kept local so this file runs
# standalone via `ruby -Ilib -Itest test/test_read_model_integration.rb`).
class ReadModelPredicateShutdown
  def initialize(&predicate)
    @predicate = predicate
  end

  def value
    @predicate.call
  end
end

class ReadModelStubBackend
  def initialize(reasons)
    @reasons = reasons.dup
  end

  def run(_prompt, images: [])
    reason = @reasons.shift || :ok
    AgentDaemon::Backend::Result.new(reason == :ok, "stdout", "stderr", reason)
  end
end

# A sink whose #publish always raises — used to prove AC6 fault isolation.
class ReadModelRaisingSink
  def publish(_entity_id, _record)
    raise "sink boom"
  end
end

# Publishes an EVENT (not state) before crashing, so its generation survives
# in the bus's history across a respawn — StateRegistry only keeps the
# latest entry per entity, but EventBus retains the full ordered log.
class ReadModelPublishingCrashFake
  def initialize(bundle)
    @bundle = bundle
  end

  def run
    @bundle.publish_event(type: :hello, at: Time.now.utc.iso8601)
    raise "boom"
  end
end

class ReadModelCrashingEntity
  def initialize(bundle)
    @bundle = bundle
  end

  def run
    @bundle.publish_state(status: :in_progress, work_item: "TASK-1.yml", attempt: 1)
    raise "boom"
  end
end

class TestReadModelIntegration < Minitest::Test
  include LogStubbing

  ISO8601_RE = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/

  def setup
    stub_null_logger!
  end

  def teardown
    restore_logger!
  end

  def build_file_runner(tmpdir, sinks:)
    project_path = File.join(tmpdir, "project")
    message_dir = File.join(project_path, "to_message")
    input_dir = File.join(project_path, "inbox")
    archive_dir = File.join(input_dir, "archive")
    failed_dir = File.join(input_dir, "failed")
    FileUtils.mkdir_p(message_dir)
    FileUtils.mkdir_p(input_dir)

    template_path = File.join(tmpdir, "prompt.txt")
    File.write(template_path, "review {{input_file}}")

    runner_config = {
      "name" => "reviewer",
      "backend" => "claude",
      "extra_flags" => "",
      "timeout" => 1200,
      "max_attempts" => 2,
      "prompt_template" => "prompt.txt",
      "prompt_template_path" => template_path,
      "trigger" => {
        "type" => "file",
        "input_dir" => input_dir,
        "archive_dir" => archive_dir,
        "failed_dir" => failed_dir,
        "interval" => 0
      }
    }

    work_item_path = File.join(input_dir, "TASK-1.yml")
    File.write(work_item_path, "body")

    shutdown = ReadModelPredicateShutdown.new { false }
    runner = AgentDaemon::Runner::File.new(runner_config, message_dir, project_path, shutdown, sinks: sinks)
    runner.instance_variable_set(:@backend, ReadModelStubBackend.new([:ok]))

    [runner, work_item_path, archive_dir]
  end

  # --- Real Runner::File through a real Sinks::Bundle + GenerationStamp ----

  def test_real_runner_file_process_item_ends_at_waiting_and_bus_holds_full_lifecycle_with_generation_and_at
    Dir.mktmpdir do |tmpdir|
      registry = AgentDaemon::Supervisor::StateRegistry.new
      bus = AgentDaemon::Supervisor::EventBus.new
      entity_id = "ent-1"
      bundle = AgentDaemon::Sinks::Bundle.new(
        entity_id: entity_id,
        state: AgentDaemon::Supervisor::GenerationStamp.new(1, registry),
        event: AgentDaemon::Supervisor::GenerationStamp.new(1, bus)
      )

      runner, work_item_path, = build_file_runner(tmpdir, sinks: bundle)
      runner.send(:process_item, work_item_path)

      assert_equal :waiting, registry.snapshot(entity_id)[:status]

      cursor = bus.subscribe
      records = bus.read(cursor)
      assert_equal [:picked_up, :started, :finished], records.map { |r| r[:type] }

      finished = records.find { |r| r[:type] == :finished }
      assert_equal :ok, finished[:reason]

      records.each do |record|
        assert_equal 1, record[:generation]
        assert_match ISO8601_RE, record[:at]
      end
    end
  end

  # --- Real RunnerSupervisor: same-generation :crashed overwrite -----------

  def test_runner_supervisor_crash_ends_registry_at_crashed_same_generation_no_stale_work_item
    registry = AgentDaemon::Supervisor::StateRegistry.new
    bus = AgentDaemon::Supervisor::EventBus.new
    entity_id = "ent-1"
    sinks_factory = lambda do |generation|
      AgentDaemon::Sinks::Bundle.new(
        entity_id: entity_id,
        state: AgentDaemon::Supervisor::GenerationStamp.new(generation, registry),
        event: AgentDaemon::Supervisor::GenerationStamp.new(generation, bus)
      )
    end

    supervisor = AgentDaemon::Supervisor::RunnerSupervisor.new(
      entity_id,
      entity_factory: ->(bundle, _cancel_token = nil) { ReadModelCrashingEntity.new(bundle) },
      shutdown_flag: AgentDaemon::ShutdownFlag.new,
      sinks_factory: sinks_factory
    )

    supervisor.spawn!
    assert supervisor.thread.join(1), "the entity thread did not terminate within 1s"
    supervisor.tick

    entry = registry.snapshot(entity_id)
    assert_equal :crashed, entry[:status]
    assert_equal 1, entry[:generation]
    refute entry.key?(:work_item), "the crashed overwrite must not carry the dying instance's stale work_item"
  end

  # --- Real Master: injected sinks_factory writes into the master's own ----
  # --- registry/bus, generation-stamped across a crash-and-respawn --------

  def with_master_config(event_bus_capacity: nil)
    Dir.mktmpdir do |dir|
      wf_dir = File.join(dir, "workflows")
      FileUtils.mkdir_p(File.join(wf_dir, "prompts"))
      File.write(File.join(wf_dir, "prompts", "default.txt"), "Prompt {{task_key}}")

      data = {
        "project_path" => File.join(dir, "proj"),
        "message_dir" => "to_message",
        "tracker" => { "token" => "t", "org_id" => "o" },
        "runners" => [
          { "name" => "a", "prompt_template" => "prompts/default.txt",
            "trigger" => { "type" => "tracker", "query" => "Queue: TI" } }
        ]
      }
      File.write(File.join(wf_dir, "wf.yml"), data.to_yaml)

      path = File.join(dir, "supervisor.yml")
      supervisor_data = { "workflows" => [{ "name" => "wf", "config" => "workflows/wf.yml" }] }
      supervisor_data["event_bus_capacity"] = event_bus_capacity if event_bus_capacity
      File.write(path, supervisor_data.to_yaml)

      yield AgentDaemon::Supervisor::Config.new(path)
    end
  end

  def test_master_build_supervisors_injects_sinks_factory_writing_generation_stamped_records_into_its_own_registry_and_bus
    with_master_config do |config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      master.instance_variable_get(:@entity_factories)[:"runner:wf:a"] =
        ->(bundle, _cancel_token = nil) { ReadModelPublishingCrashFake.new(bundle) }

      master.send(:build_supervisors)
      supervisor = master.instance_variable_get(:@supervisors).fetch(:"runner:wf:a")
      supervisor.instance_variable_set(:@restart_delay, 0.02)
      entity_id = master.instance_variable_get(:@entity_ids).fetch(:"runner:wf:a")

      master.send(:start_supervisors)
      assert supervisor.thread.join(1), "the gen-1 entity thread did not terminate within 1s"
      supervisor.tick

      # The STATE half of the injected factory. handle_thread_death publishes
      # {status: :crashed} through the very bundle read_model_sinks_factory
      # built, so it must land in the MASTER's own registry, generation-
      # stamped. Without this assertion the `state:` leg of the factory could
      # be deleted outright — Bundle would fall back to NullState — and the
      # whole suite would still pass.
      crashed = master.state_registry.snapshot(entity_id)
      refute_nil crashed, "nothing reached the master's registry — the sinks_factory's `state:` leg is not wired"
      assert_equal :crashed, crashed[:status]
      assert_equal 1, crashed[:generation]

      sleep(0.05)
      supervisor.tick
      assert supervisor.thread.join(1), "the gen-2 entity thread did not terminate within 1s"

      assert_equal :running, supervisor.state
      assert_equal 2, supervisor.generation

      cursor = master.event_bus.subscribe
      hello_records = master.event_bus.read(cursor).select { |r| r[:type] == :hello }

      assert_equal [1, 2], hello_records.map { |r| r[:generation] }
      assert(hello_records.all? { |r| r[:entity_id] == entity_id })
    end
  end

  # The operator-tunable capacity must actually reach the master's single bus,
  # not merely parse and validate in Supervisor::Config.
  def test_master_builds_its_event_bus_with_the_configured_capacity
    with_master_config(event_bus_capacity: 2) do |config|
      master = AgentDaemon::Supervisor::Master.new(config)
      cursor = master.event_bus.subscribe

      3.times { |i| master.event_bus.publish("ent-1", { type: :"e#{i}", generation: 1 }) }

      assert_equal 1, master.event_bus.events_dropped_total
      assert_equal %i[e1 e2], master.event_bus.read(cursor).map { |r| r[:type] }
    end
  end

  # --- AC6: fault isolation, end-to-end -------------------------------------

  def test_raising_registry_and_bus_never_break_item_processing
    Dir.mktmpdir do |tmpdir|
      bundle = AgentDaemon::Sinks::Bundle.new(
        entity_id: "ent-1", state: ReadModelRaisingSink.new, event: ReadModelRaisingSink.new
      )
      runner, work_item_path, archive_dir = build_file_runner(tmpdir, sinks: bundle)

      runner.send(:process_item, work_item_path)

      assert File.exist?(File.join(archive_dir, "TASK-1.yml")), "item must complete despite raising registry/bus"
      refute File.exist?(work_item_path)
    end
  end

  # RunnerSupervisor#handle_thread_death publishes :crashed from the MASTER
  # thread (Master#supervise_until_shutdown's `@supervisors.each_value(&:tick)`
  # loop) — a raising registry there must not abort that loop and strand the
  # other entities un-ticked.
  def test_raising_registry_during_master_thread_publish_does_not_abort_tick_of_other_entities
    crashing_sinks_factory = lambda do |generation|
      AgentDaemon::Sinks::Bundle.new(
        entity_id: "ent-1", state: AgentDaemon::Supervisor::GenerationStamp.new(generation, ReadModelRaisingSink.new)
      )
    end
    crashing_supervisor = AgentDaemon::Supervisor::RunnerSupervisor.new(
      "ent-1",
      entity_factory: ->(_bundle, _cancel_token = nil) { Class.new { def run = raise("boom") }.new },
      shutdown_flag: AgentDaemon::ShutdownFlag.new,
      sinks_factory: crashing_sinks_factory
    )

    healthy_registry = AgentDaemon::Supervisor::StateRegistry.new
    healthy_sinks_factory = lambda do |generation|
      AgentDaemon::Sinks::Bundle.new(
        entity_id: "ent-2", state: AgentDaemon::Supervisor::GenerationStamp.new(generation, healthy_registry)
      )
    end
    healthy_supervisor = AgentDaemon::Supervisor::RunnerSupervisor.new(
      "ent-2",
      entity_factory: ->(_bundle, _cancel_token = nil) { Class.new { def run = nil }.new },
      shutdown_flag: AgentDaemon::ShutdownFlag.new,
      sinks_factory: healthy_sinks_factory
    )

    supervisors = { a: crashing_supervisor, b: healthy_supervisor }
    supervisors.each_value(&:spawn!)
    assert crashing_supervisor.thread.join(1), "the crashing entity thread did not terminate within 1s"
    assert healthy_supervisor.thread.join(1), "the healthy entity thread did not terminate within 1s"

    # Mirrors Master#supervise_until_shutdown's tick loop: one entity's
    # raising sink must not raise out of the loop and skip the rest.
    supervisors.each_value(&:tick)

    assert_equal :restarting, crashing_supervisor.state
    assert_equal :exited, healthy_supervisor.state
    assert_equal :exited, healthy_registry.snapshot("ent-2")[:status]
  end
end
