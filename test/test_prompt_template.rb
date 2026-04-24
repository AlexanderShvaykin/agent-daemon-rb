# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "stringio"

class TestPromptTemplate < Minitest::Test
  def setup
    null_logger = ::Logger.new(File::NULL)
    null_logger.level = ::Logger::FATAL
    AgentDaemon::Log.instance_variable_set(:@logger, null_logger)
  end

  def with_template(body)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "t.txt")
      File.write(path, body)
      yield AgentDaemon::PromptTemplate.new(path), path
    end
  end

  def test_substitutes_runner_keys
    with_template("hello {{signature}}") do |t, _|
      assert_equal "hello World", t.render("signature" => "World")
    end
  end

  def test_substitutes_task_key
    with_template("task {{task_key}}") do |t, _|
      assert_equal "task TI-42", t.render("task_key" => "TI-42")
    end
  end

  def test_substitutes_input_file
    with_template("file {{input_file}}") do |t, _|
      assert_equal "file /tmp/x.yml", t.render("input_file" => "/tmp/x.yml")
    end
  end

  def test_substitutes_message_dir
    with_template("dir {{message_dir}}") do |t, _|
      assert_equal "dir /var/messages", t.render("message_dir" => "/var/messages")
    end
  end

  def test_substitutes_output_dir_when_present
    with_template("out {{output_dir}}") do |t, _|
      assert_equal "out /var/out", t.render("output_dir" => "/var/out")
    end
  end

  def test_undefined_variable_preserved_and_warned
    io = StringIO.new
    capture_logger = ::Logger.new(io)
    capture_logger.level = ::Logger::WARN
    AgentDaemon::Log.instance_variable_set(:@logger, capture_logger)

    with_template("a {{undefined_var}} b") do |t, _|
      result = t.render({})
      assert_equal "a {{undefined_var}} b", result
      assert_includes io.string, "undefined_var"
    end
  end

  def test_undefined_input_file_on_tracker_runner_preserved
    with_template("{{input_file}}") do |t, _|
      assert_equal "{{input_file}}", t.render("task_key" => "TI-1")
    end
  end

  def test_undefined_output_dir_on_runner_without_one
    with_template("{{output_dir}}") do |t, _|
      assert_equal "{{output_dir}}", t.render({})
    end
  end

  def test_missing_template_file_raises
    err = assert_raises(RuntimeError) { AgentDaemon::PromptTemplate.new("/nope/missing.txt") }
    assert_includes err.message, "/nope/missing.txt"
  end
end
