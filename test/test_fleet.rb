# frozen_string_literal: true

require "test_helper"

# AD-5 lazy-require isolation: required explicitly here, never from the core
# `require "agent_daemon"` graph.
require "agent_daemon/supervisor/fleet"
require "agent_daemon/supervisor/state_registry"
require "agent_daemon/supervisor/runner_identity"

class TestFleet < Minitest::Test
  Fleet = AgentDaemon::Supervisor::Fleet
  Rostered = Fleet::Rostered
  StateRegistry = AgentDaemon::Supervisor::StateRegistry
  RunnerIdentity = AgentDaemon::Supervisor::RunnerIdentity

  # No LogStubbing here on purpose: fleet.rb requires nothing and touches
  # nothing but StateRegistry#all, so it makes no Log.* call to stub.

  def setup
    @registry = StateRegistry.new
  end

  def runner_identity(workflow, runner)
    RunnerIdentity.new(workflow: workflow, runner: runner)
  end

  # --- AC1/AC5: roster order, state joined ---------------------------------

  def test_entries_follow_roster_order_regardless_of_publish_order
    id_a = runner_identity("wf", "a")
    id_b = runner_identity("wf", "b")
    roster = [
      Rostered.new(kind: :runner, workflow: "wf", name: "a", entity_id: id_a),
      Rostered.new(kind: :runner, workflow: "wf", name: "b", entity_id: id_b)
    ]
    @registry.publish(id_b, { status: :waiting, generation: 1 })
    @registry.publish(id_a, { status: :waiting, generation: 1 })

    fleet = Fleet.new(roster: roster, state_registry: @registry)

    assert_equal %w[a b], fleet.entries.map(&:name)
  end

  # Master hands us the very array it keeps appending to in build_factories.
  # Freezing that object in place instead of a copy turns the next
  # `@roster << …` into a FrozenError, aborting boot.
  def test_construction_does_not_freeze_the_callers_roster
    roster = []
    fleet = Fleet.new(roster: roster, state_registry: @registry)

    roster << Rostered.new(kind: :runner, workflow: "wf", name: "late", entity_id: runner_identity("wf", "late"))

    refute_predicate roster, :frozen?
    assert_empty fleet.entries, "the Fleet keeps the roster it was built from, not a live view of it"
  end

  # #workflows and #fleet_wide must be able to project one already-taken
  # read, so a page render is a single registry acquisition.
  def test_workflows_and_fleet_wide_project_a_caller_supplied_entries_list
    roster = [
      Rostered.new(kind: :runner, workflow: "wf", name: "a", entity_id: runner_identity("wf", "a")),
      Rostered.new(kind: :reactor, workflow: nil, name: "mattermost_reactor", entity_id: "mattermost_reactor")
    ]
    fleet = Fleet.new(roster: roster, state_registry: @registry)

    entries = fleet.entries

    assert_equal %w[a], fleet.workflows(entries).assoc("wf").last.map(&:name)
    assert_equal %w[mattermost_reactor], fleet.fleet_wide(entries).map(&:name)
    assert_same entries.first, fleet.workflows(entries).assoc("wf").last.first
  end

  # --- AC3: every published status maps to its liveness --------------------

  def test_every_published_status_maps_to_its_liveness
    expected = {
      waiting: :alive,
      in_progress: :alive,
      running: :alive,
      crashed: :restarting,
      exited: :dead,
      stopped: :dead
    }

    expected.each do |status, liveness|
      id = runner_identity("wf", status.to_s)
      registry = StateRegistry.new
      registry.publish(id, { status: status, generation: 1 })
      roster = [Rostered.new(kind: :runner, workflow: "wf", name: status.to_s, entity_id: id)]

      fleet = Fleet.new(roster: roster, state_registry: registry)
      entry = fleet.entries.first

      assert_equal status, entry.status
      assert_equal liveness, entry.liveness, "status #{status.inspect} must map to #{liveness.inspect}"
    end
  end

  # The test above pins the mapping but shares its table with LIVENESS, so it
  # can only catch a *changed* mapping, never an incomplete one. This is the
  # assertion with teeth: the map's header claims it "covers the complete
  # published vocabulary with no fall-through", and that claim is about lib/,
  # not about this file. A publish_state(status: :draining) added tomorrow
  # renders `unknown` with a blank note — this test is what notices.
  def test_liveness_covers_every_status_published_anywhere_in_lib
    lib = File.expand_path("../lib", __dir__)
    published = Dir.glob(File.join(lib, "**", "*.rb")).flat_map do |path|
      File.read(path).scan(/publish_state\(status: :(\w+)/).flatten
    end.map(&:to_sym).uniq

    refute_empty published, "found no publish_state call sites — the scan is broken, not the map"
    unmapped = published - Fleet::LIVENESS.keys
    assert_empty unmapped, "statuses published in lib/ but absent from Fleet::LIVENESS: #{unmapped.inspect}"
  end

  # --- AC5: no snapshot at all -> :unknown, never absent --------------------

  def test_a_rostered_entity_with_no_snapshot_is_unknown
    id = runner_identity("wf", "never-published")
    roster = [Rostered.new(kind: :runner, workflow: "wf", name: "never-published", entity_id: id)]

    fleet = Fleet.new(roster: roster, state_registry: @registry)
    entry = fleet.entries.first

    assert_nil entry.status
    assert_equal :unknown, entry.liveness
  end

  # --- AC3: an unrecognised status is :unknown, never a fall-through -------

  def test_an_unrecognised_status_is_unknown_not_alive
    id = runner_identity("wf", "weird")
    @registry.publish(id, { status: :some_future_status, generation: 1 })
    roster = [Rostered.new(kind: :runner, workflow: "wf", name: "weird", entity_id: id)]

    fleet = Fleet.new(roster: roster, state_registry: @registry)
    entry = fleet.entries.first

    assert_equal :some_future_status, entry.status
    assert_equal :unknown, entry.liveness
  end

  def test_a_snapshot_with_no_status_key_is_unknown
    id = runner_identity("wf", "no-status-key")
    @registry.publish(id, { generation: 1 })
    roster = [Rostered.new(kind: :runner, workflow: "wf", name: "no-status-key", entity_id: id)]

    fleet = Fleet.new(roster: roster, state_registry: @registry)
    entry = fleet.entries.first

    assert_nil entry.status
    assert_equal :unknown, entry.liveness
  end

  # --- AC2: grouping -----------------------------------------------------

  def test_workflows_groups_runners_and_messenger_under_their_workflow_in_config_order
    id_a = runner_identity("wfA", "a")
    id_b = runner_identity("wfB", "b")
    roster = [
      Rostered.new(kind: :runner, workflow: "wfA", name: "a", entity_id: id_a),
      Rostered.new(kind: :messenger, workflow: "wfA", name: "messenger", entity_id: "messenger:wfA"),
      Rostered.new(kind: :runner, workflow: "wfB", name: "b", entity_id: id_b),
      Rostered.new(kind: :reactor, workflow: nil, name: "mattermost_reactor", entity_id: "mattermost_reactor")
    ]
    fleet = Fleet.new(roster: roster, state_registry: @registry)

    workflows = fleet.workflows

    assert_equal %w[wfA wfB], workflows.map(&:first)
    wf_a_names = workflows.assoc("wfA").last.map(&:name)
    assert_equal %w[a messenger], wf_a_names
    wf_b_names = workflows.assoc("wfB").last.map(&:name)
    assert_equal %w[b], wf_b_names
  end

  def test_fleet_wide_holds_only_the_reactor
    id_a = runner_identity("wf", "a")
    roster = [
      Rostered.new(kind: :runner, workflow: "wf", name: "a", entity_id: id_a),
      Rostered.new(kind: :reactor, workflow: nil, name: "mattermost_reactor", entity_id: "mattermost_reactor")
    ]
    fleet = Fleet.new(roster: roster, state_registry: @registry)

    fleet_wide = fleet.fleet_wide

    assert_equal [:reactor], fleet_wide.map(&:kind)
    assert_equal ["mattermost_reactor"], fleet_wide.map(&:name)
  end

  def test_fleet_wide_is_empty_when_there_is_no_reactor
    id_a = runner_identity("wf", "a")
    roster = [Rostered.new(kind: :runner, workflow: "wf", name: "a", entity_id: id_a)]
    fleet = Fleet.new(roster: roster, state_registry: @registry)

    assert_empty fleet.fleet_wide
  end

  # --- Story 2.4: #find and the detail fields -------------------------------

  def test_find_locates_each_of_the_three_id_shapes_and_nil_for_unknown
    runner_id = runner_identity("wf", "alpha")
    roster = [
      Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: runner_id),
      Rostered.new(kind: :messenger, workflow: "wf", name: "messenger", entity_id: "messenger:wf"),
      Rostered.new(kind: :reactor, workflow: nil, name: "mattermost_reactor", entity_id: "mattermost_reactor")
    ]
    fleet = Fleet.new(roster: roster, state_registry: @registry)

    assert_equal "alpha", fleet.find("runner:wf:alpha").name
    assert_equal "messenger", fleet.find("messenger:wf").name
    assert_equal "mattermost_reactor", fleet.find("mattermost_reactor").name
    assert_nil fleet.find("unknown")
  end

  def test_an_in_progress_snapshot_surfaces_work_item_attempt_and_generation
    id = runner_identity("wf", "alpha")
    @registry.publish(id, { status: :in_progress, work_item: "T-1", attempt: 2, generation: 3 })
    roster = [Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    fleet = Fleet.new(roster: roster, state_registry: @registry)

    entry = fleet.entries.first

    assert_equal "T-1", entry.work_item
    assert_equal 2, entry.attempt
    assert_equal 3, entry.generation
  end

  # AC6, driven for real (not stubbed): the supervisor's same-generation
  # :crashed publish is a full overwrite (state_registry.rb:50-57), so it
  # must erase the dying instance's own last :in_progress work_item/attempt
  # rather than leave them stale.
  def test_a_same_generation_crash_erases_the_last_in_progress_work_item
    id = runner_identity("wf", "flaky")
    @registry.publish(id, { status: :in_progress, work_item: "T-1", attempt: 2, generation: 1 })
    @registry.publish(id, { status: :crashed, generation: 1 })
    roster = [Rostered.new(kind: :runner, workflow: "wf", name: "flaky", entity_id: id)]
    fleet = Fleet.new(roster: roster, state_registry: @registry)

    entry = fleet.entries.first

    assert_nil entry.work_item
    assert_nil entry.attempt
    assert_equal :restarting, entry.liveness
  end

  # --- Story 2.4: stuck_restarting (clock injected, no sleep) ---------------

  def test_stuck_restarting_is_false_for_a_freshly_crashed_entity
    id = runner_identity("wf", "flaky")
    @registry.publish(id, { status: :crashed, generation: 1 })
    published_at = @registry.snapshot(id).fetch(:observed_monotonic)
    roster = [Rostered.new(kind: :runner, workflow: "wf", name: "flaky", entity_id: id)]
    fleet = Fleet.new(roster: roster, state_registry: @registry, restart_delay: 60, clock: -> { published_at + 1 })

    refute fleet.entries.first.stuck_restarting
  end

  def test_stuck_restarting_is_true_once_elapsed_exceeds_restart_delay_plus_margin
    id = runner_identity("wf", "flaky")
    @registry.publish(id, { status: :crashed, generation: 1 })
    published_at = @registry.snapshot(id).fetch(:observed_monotonic)
    roster = [Rostered.new(kind: :runner, workflow: "wf", name: "flaky", entity_id: id)]
    fleet = Fleet.new(roster: roster, state_registry: @registry, restart_delay: 60, clock: -> { published_at + 66 })

    entry = fleet.entries.first

    assert entry.stuck_restarting
    assert_equal 66, entry.seconds_since_published
  end

  def test_stuck_restarting_is_false_for_an_in_progress_entity_of_any_age
    id = runner_identity("wf", "busy")
    @registry.publish(id, { status: :in_progress, work_item: "T-1", attempt: 1, generation: 1 })
    published_at = @registry.snapshot(id).fetch(:observed_monotonic)
    roster = [Rostered.new(kind: :runner, workflow: "wf", name: "busy", entity_id: id)]
    fleet = Fleet.new(roster: roster, state_registry: @registry, restart_delay: 60,
                       clock: -> { published_at + 1_000_000 })

    refute fleet.entries.first.stuck_restarting
  end

  def test_stuck_restarting_is_false_when_restart_delay_is_nil
    id = runner_identity("wf", "flaky")
    @registry.publish(id, { status: :crashed, generation: 1 })
    published_at = @registry.snapshot(id).fetch(:observed_monotonic)
    roster = [Rostered.new(kind: :runner, workflow: "wf", name: "flaky", entity_id: id)]
    fleet = Fleet.new(roster: roster, state_registry: @registry, restart_delay: nil,
                       clock: -> { published_at + 1_000_000 })

    refute fleet.entries.first.stuck_restarting
  end

  # --- Story 3.5 DR2: the raw entity_id rides along for the output join ----

  # OutputBuffers keys its buffers by the raw entity_id the pipeline saw (a
  # RunnerIdentity Struct for runners), not by the derived String #id. If
  # Entry only carried #id, the console could never look output up for a
  # runner at all.
  def test_entry_carries_the_raw_entity_id_alongside_the_derived_id
    id = runner_identity("wf", "alpha")
    roster = [Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    fleet = Fleet.new(roster: roster, state_registry: @registry)

    entry = fleet.entries.first

    assert_same id, entry.entity_id
    assert_equal "runner:wf:alpha", entry.id
  end

  def test_entry_carries_the_opaque_string_entity_id_for_a_messenger
    roster = [Rostered.new(kind: :messenger, workflow: "wf", name: "messenger", entity_id: "messenger:wf")]
    fleet = Fleet.new(roster: roster, state_registry: @registry)

    entry = fleet.entries.first

    assert_equal "messenger:wf", entry.entity_id
  end

  # --- Empty roster ---------------------------------------------------------

  def test_an_empty_roster_yields_empty_results
    fleet = Fleet.new(roster: [], state_registry: @registry)

    assert_empty fleet.entries
    assert_empty fleet.workflows
    assert_empty fleet.fleet_wide
  end
end
