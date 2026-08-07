# frozen_string_literal: true

require "test_helper"

# AD-5 lazy-require isolation: the supervisor file is loaded explicitly here
# and is NOT part of the core `require "agent_daemon"` graph.
require "agent_daemon/supervisor/redactor"

class TestRedactor < Minitest::Test
  MARKER = "[REDACTED]"

  def redactor(*values)
    AgentDaemon::Supervisor::Redactor.new(values.flatten)
  end

  def test_every_occurrence_on_a_line_is_replaced
    r = redactor("sekret-value-1")

    assert_equal "a #{MARKER} b #{MARKER} c",
                 r.redact("a sekret-value-1 b sekret-value-1 c")
  end

  def test_the_marker_is_exactly_redacted
    assert_equal MARKER, redactor("sekret-value-1").redact("sekret-value-1")
  end

  # The marker must not encode which secret matched or how long it was: both
  # leak information about the value.
  def test_the_marker_is_identical_for_values_of_different_lengths
    r = redactor("short", "a-much-longer-sekret-value")

    assert_equal "#{MARKER}|#{MARKER}", r.redact("short|a-much-longer-sekret-value")
  end

  def test_duplicates_behave_exactly_like_a_single_entry
    line = "x sekret-value-1 y"

    assert_equal redactor("sekret-value-1").redact(line),
                 redactor("sekret-value-1", "sekret-value-1", "sekret-value-1").redact(line)
    assert_equal "x #{MARKER} y", redactor("sekret-value-1", "sekret-value-1").redact(line)
  end

  # AC5: an empty value must be ignored, not matched at every position.
  # The positive control in the same test proves the redactor is live.
  def test_empty_and_nil_values_are_ignored_and_match_nothing
    r = redactor(nil, "", "sekret-value-1")
    line = "plain text with no marker"

    assert_equal line, r.redact(line)
    assert_equal "hit #{MARKER}", r.redact("hit sekret-value-1"), "positive control: a real value IS redacted"
  end

  def test_an_only_empty_value_set_leaves_the_line_byte_identical
    line = "plain text with no marker"

    assert_equal line, redactor(nil, "", nil).redact(line)
  end

  def test_an_empty_value_set_returns_the_input_unchanged
    assert_equal "anything at all", redactor.redact("anything at all")
  end

  # DR2: without a longest-first sort, Regexp alternation's leftmost-first
  # semantics leave the longer secret's tail exposed.
  def test_a_value_that_prefixes_a_longer_value_still_redacts_the_longer_one_completely
    r = redactor("sekret", "sekret-value-1")

    assert_equal MARKER, r.redact("sekret-value-1")
    assert_equal MARKER, r.redact("sekret"), "positive control: the short value is redacted too"
  end

  def test_declaration_order_does_not_matter
    line = "sekret-value-1"

    assert_equal redactor("sekret", "sekret-value-1").redact(line),
                 redactor("sekret-value-1", "sekret").redact(line)
  end

  # Regexp.union escapes each value, so metacharacters match literally.
  def test_regexp_metacharacters_in_a_secret_are_literal
    r = redactor("a.b*c", "[x]", "end$")

    assert_equal MARKER, r.redact("a.b*c")
    assert_equal MARKER, r.redact("[x]")
    assert_equal MARKER, r.redact("end$")
  end

  def test_a_lookalike_that_the_metacharacters_would_have_matched_is_not_redacted
    r = redactor("a.b*c")

    assert_equal "aXbbbc", r.redact("aXbbbc")
    assert_equal MARKER, r.redact("a.b*c"), "positive control: the literal value IS redacted"
  end

  def test_a_backslash_in_a_secret_is_literal
    r = redactor('c:\\path\\to')

    assert_equal MARKER, r.redact('c:\\path\\to')
    assert_equal "c:XpathXto", r.redact("c:XpathXto")
  end

  # The pipeline feeds one line at a time; the Redactor itself is line-agnostic.
  def test_a_multiline_string_is_not_special_cased
    r = redactor("sekret-value-1")

    assert_equal "a #{MARKER}\nb #{MARKER}\n", r.redact("a sekret-value-1\nb sekret-value-1\n")
  end

  def test_redact_returns_a_string_and_leaves_the_argument_untouched
    r = redactor("sekret-value-1")
    line = +"x sekret-value-1"

    result = r.redact(line)

    assert_kind_of String, result
    assert_equal "x sekret-value-1", line
  end

  # The compiled Regexp embeds the secrets verbatim; the default #inspect
  # would print every one of them.
  def test_inspect_and_to_s_never_expose_a_secret
    r = redactor("sekret-value-1")

    refute_includes r.inspect, "sekret-value-1"
    refute_includes r.to_s, "sekret-value-1"
    refute_includes "#{r}", "sekret-value-1"
    assert_equal "[REDACTED]", r.redact("sekret-value-1"), "positive control: the redactor does hold the value"
  end

  def test_a_pipeline_holding_a_redactor_does_not_expose_a_secret_through_inspect
    require "agent_daemon/supervisor/output_pipeline"
    pipeline = AgentDaemon::Supervisor::OutputPipeline.new(redactor: redactor("sekret-value-1"))

    refute_includes pipeline.inspect, "sekret-value-1"
  end

  def test_non_string_entries_are_ignored
    r = redactor(nil, 42, :sym, "sekret-value-1")

    assert_equal MARKER, r.redact("sekret-value-1")
  end

  # The pipeline redacts scrubbed UTF-8 lines. A secret carrying invalid
  # bytes must neither raise Encoding::CompatibilityError inside gsub (which
  # would silently drop every non-ASCII line at the sink guard) nor go
  # unmatched in the scrubbed form the output actually takes.
  def test_a_secret_with_invalid_bytes_matches_its_scrubbed_form_and_never_raises
    r = redactor("sekret-value-1", "bad\xFFsecret".b)

    assert_equal "x #{MARKER} y", r.redact("x sekret-value-1 y"), "positive control"
    assert_equal "x #{MARKER} y", r.redact("x bad\u{FFFD}secret y"),
                 "the scrubbed form of the secret must match"
    assert_equal "héllo wörld", r.redact("héllo wörld"),
                 "a non-ASCII line without the secret must pass through, not raise"
  end

  def test_a_binary_encoded_valid_utf8_secret_matches_the_utf8_line
    r = redactor("café-sekret".b)

    assert_equal "x #{MARKER} y", r.redact("x café-sekret y")
  end

  # --- max_value_length (Story 3.4 DR9) -------------------------------------

  def test_max_value_length_is_zero_for_an_empty_set
    assert_equal 0, redactor.max_value_length
  end

  def test_max_value_length_is_the_longest_values_bytesize
    r = redactor("short", "a-much-longer-sekret-value")

    assert_equal "a-much-longer-sekret-value".bytesize, r.max_value_length
  end

  def test_max_value_length_uses_bytesize_not_character_length_for_multibyte_values
    r = redactor("café-sekret")

    assert_equal "café-sekret".bytesize, r.max_value_length
    refute_equal "café-sekret".length, r.max_value_length
  end
end
