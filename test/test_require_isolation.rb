# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

# AD-5 (lazy-require dependency isolation): the standalone core load path
# (`require "agent_daemon"` / bin/agent-daemon) must never pull in supervisor
# code or supervisor-only deps. The whole Minitest suite runs in ONE process
# and sibling test files (test_supervisor_master.rb, test_runner_supervisor.rb,
# test_supervisor_config.rb, ...) already `require` supervisor files before
# this test runs, so $LOADED_FEATURES is polluted in-process by the time we
# get here. We therefore shell out to a clean child Ruby process that does
# only `require "agent_daemon"` and inspect *its* $LOADED_FEATURES.
class TestRequireIsolation < Minitest::Test
  LIB = File.expand_path("../lib", __dir__)

  def run_core_probe(script)
    Open3.capture2e(RbConfig.ruby, "-I", LIB, "-e", script)
  end

  # bin/agent-daemon's only require is `require_relative "../lib/agent_daemon"`,
  # so `require "agent_daemon"` in a clean process is a faithful stand-in for
  # the CLI's load graph. We do NOT boot the daemon (it starts threads) —
  # asserting the require graph is the AC; do not "strengthen" this by
  # launching the process.
  def test_core_require_graph_loads_no_supervisor_code_or_deps
    script = <<~RUBY
      require "agent_daemon"
      bad = []
      bad.concat($LOADED_FEATURES.grep(%r{/agent_daemon/supervisor/}))
      # sqlite3/puma/rack/oauth2 are not gemspec deps yet (they land in Epics
      # 2/5/6), so this check trivially holds today. Matching by feature PATH
      # (not a rescue-able `require`) means it starts guarding the core->dep
      # boundary the moment those gems are added later, with no test edit.
      bad.concat($LOADED_FEATURES.grep(%r{/(sqlite3|puma|rack|oauth2)(/|\\.rb|\\.so|\\.bundle)}))
      bad << "AgentDaemon::Supervisor defined" if defined?(AgentDaemon::Supervisor)
      unless bad.empty?
        warn "LEAKED: \#{bad.inspect}"
        exit 1
      end
    RUBY
    out, status = run_core_probe(script)
    assert status.success?, "core require graph leaked supervisor/deps:\n#{out}"
  end

  # Negative control: proves the supervisor tree IS loadable, so its absence
  # from the core graph above is a real isolation property, not a vacuous
  # pass because the supervisor code is broken or missing entirely.
  def test_supervisor_tree_is_loadable_in_isolation
    script = <<~RUBY
      require "agent_daemon/supervisor/master"
      exit(defined?(AgentDaemon::Supervisor::Master) ? 0 : 1)
    RUBY
    out, status = run_core_probe(script)
    assert status.success?, "supervisor tree failed to load in isolation:\n#{out}"
  end

  def test_gemspec_declares_both_executables
    spec = Gem::Specification.load(File.expand_path("../agent_daemon.gemspec", __dir__))
    assert_includes spec.executables, "agent-daemon"
    assert_includes spec.executables, "agent-supervisor"
    assert File.executable?(File.expand_path("../bin/agent-supervisor", __dir__))
  end
end
