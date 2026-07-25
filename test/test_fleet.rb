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

  # --- Empty roster ---------------------------------------------------------

  def test_an_empty_roster_yields_empty_results
    fleet = Fleet.new(roster: [], state_registry: @registry)

    assert_empty fleet.entries
    assert_empty fleet.workflows
    assert_empty fleet.fleet_wide
  end
end
