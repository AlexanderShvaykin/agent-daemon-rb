# frozen_string_literal: true

require "test_helper"

# AD-5 lazy-require isolation: console files (and the oauth2 gem they pull in)
# are loaded explicitly here, never from the core graph.
require "agent_daemon/supervisor/console/gitlab_oauth"

# Story 2.2 AC3 — the ONE network seam. Every case here is offline (Epic 1
# retro AI-2, which names GitLab OAuth in 2.2 by name): the access token is a
# collaborator double and the OAuth2 client is swapped for the two cases that
# reach it. No test in this file touches a socket.
class TestConsoleGitlabOAuth < Minitest::Test
  OAuthClient = AgentDaemon::Supervisor::Console::GitlabOAuth

  HOST = "https://gitlab.example.com"
  REDIRECT_URI = "https://console.example.com/auth/callback"

  # Stands in for OAuth2::AccessToken: records every request and replies from a
  # handler, so tests assert on the exact params sent to GitLab.
  class FakeToken
    Response = Struct.new(:parsed, :headers)

    attr_reader :requests

    def initialize(&handler)
      @handler = handler
      @requests = []
    end

    def get(path, opts = {})
      @requests << [path, opts]
      @handler.call(path, opts)
    end
  end

  class FakeAuthCode
    attr_reader :calls

    def initialize(&handler)
      @handler = handler
      @calls = []
    end

    def get_token(code, opts = {})
      @calls << [code, opts]
      @handler.call(code, opts)
    end
  end

  FakeClient = Struct.new(:auth_code)

  def build(host: HOST)
    OAuthClient.new(host: host, app_id: "app-id", app_secret: "app-secret", redirect_uri: REDIRECT_URI)
  end

  # Headers are a case-insensitive Faraday::Utils::Headers in production, and
  # GitLab sends "X-Next-Page" capitalised while the code looks it up in lower
  # case. A plain lower-cased Hash here would make the test pass by
  # construction and keep passing if that lookup ever stopped matching — a
  # silent truncation of the group list, i.e. a wrong denial.
  def page(entries, next_page: nil)
    FakeToken::Response.new(entries, Faraday::Utils::Headers.new("X-Next-Page" => next_page.to_s))
  end

  # --- authorize_url -------------------------------------------------------

  def test_authorize_url_targets_the_configured_host_with_state_and_redirect
    url = build.authorize_url(state: "st4te")
    uri = URI.parse(url)
    params = URI.decode_www_form(uri.query).to_h

    assert_equal "gitlab.example.com", uri.host
    assert_equal "/oauth/authorize", uri.path
    assert_equal "app-id", params["client_id"]
    assert_equal "code", params["response_type"]
    assert_equal REDIRECT_URI, params["redirect_uri"]
    assert_equal "st4te", params["state"]
  end

  # read_user cannot read group membership: with it the group check would see
  # an empty list and deny every user. This constant is load-bearing.
  def test_authorize_url_requests_the_read_api_scope
    assert_equal "read_api", OAuthClient::SCOPE
    params = URI.decode_www_form(URI.parse(build.authorize_url(state: "s")).query).to_h
    assert_equal "read_api", params["scope"]
  end

  def test_authorize_url_honours_a_self_hosted_http_origin
    url = build(host: "http://gitlab.internal:8080").authorize_url(state: "s")
    assert url.start_with?("http://gitlab.internal:8080/oauth/authorize"), url
  end

  def test_the_secret_never_reaches_the_authorize_url
    refute_match(/app-secret/, build.authorize_url(state: "s"))
  end

  # --- exchange ------------------------------------------------------------

  # The redirect_uri must be byte-identical across authorize and token
  # exchange or GitLab rejects the code.
  def test_exchange_sends_the_code_and_the_same_redirect_uri
    oauth = build
    auth_code = FakeAuthCode.new { |_code, _opts| :the_token }
    oauth.instance_variable_set(:@client, FakeClient.new(auth_code))

    assert_equal :the_token, oauth.exchange(code: "the-code")
    assert_equal [["the-code", { redirect_uri: REDIRECT_URI }]], auth_code.calls

    # Same object graph, real client: the string both calls use must match byte
    # for byte, so compare against what authorize_url actually emits.
    authorize_params = URI.decode_www_form(URI.parse(build.authorize_url(state: "s")).query).to_h
    assert_equal authorize_params["redirect_uri"], auth_code.calls.first.last[:redirect_uri]
  end

  def test_exchange_wraps_every_transport_failure
    [OAuth2::Error.new("invalid_grant"), Faraday::TimeoutError.new("timeout"), JSON::ParserError.new("bad json")].each do |boom|
      oauth = build
      oauth.instance_variable_set(:@client, FakeClient.new(FakeAuthCode.new { raise boom }))

      err = assert_raises(OAuthClient::Error) { oauth.exchange(code: "c") }
      assert_match(/token exchange failed/, err.message)
    end
  end

  def test_exchange_error_never_leaks_the_secret
    oauth = build
    oauth.instance_variable_set(:@client, FakeClient.new(FakeAuthCode.new { raise OAuth2::Error.new("app-secret rejected") }))

    err = assert_raises(OAuthClient::Error) { oauth.exchange(code: "c") }
    refute_match(/app-secret/, err.message)
  end

  # --- fetch_username ------------------------------------------------------

  def test_fetch_username_reads_the_current_user
    token = FakeToken.new { FakeToken::Response.new({ "username" => "alice", "id" => 7 }, {}) }

    assert_equal "alice", build.fetch_username(token)
    assert_equal "/api/v4/user", token.requests.first.first
  end

  def test_fetch_username_raises_when_the_body_has_no_username
    [{ "id" => 7 }, { "username" => "" }, [], nil, "text"].each do |body|
      token = FakeToken.new { FakeToken::Response.new(body, {}) }
      err = assert_raises(OAuthClient::Error) { build.fetch_username(token) }
      assert_match(/user lookup/, err.message)
    end
  end

  def test_fetch_username_wraps_transport_failures
    token = FakeToken.new { raise Faraday::ConnectionFailed, "refused" }
    assert_raises(OAuthClient::Error) { build.fetch_username(token) }
  end

  # --- member_group_paths --------------------------------------------------

  # Without min_access_level GitLab returns every VISIBLE group, including
  # public ones the user is not a member of — the allowed-group check would
  # then read "anyone who can see the group", i.e. fail-open.
  def test_member_group_paths_requests_only_actual_memberships
    token = FakeToken.new { page([{ "full_path" => "backoffice" }]) }
    build.member_group_paths(token)

    path, opts = token.requests.first
    assert_equal "/api/v4/groups", path
    assert_equal 10, opts[:params][:min_access_level]
    assert_equal 100, opts[:params][:per_page]
    assert_equal 1, opts[:params][:page]
  end

  def test_member_group_paths_maps_full_paths
    token = FakeToken.new do
      page([{ "full_path" => "backoffice" }, { "full_path" => "platform/sre" }])
    end

    assert_equal %w[backoffice platform/sre], build.member_group_paths(token)
  end

  def test_member_group_paths_follows_pagination
    token = FakeToken.new do |_path, opts|
      case opts[:params][:page]
      when 1 then page([{ "full_path" => "a" }], next_page: 2)
      when 2 then page([{ "full_path" => "b" }], next_page: 3)
      else page([{ "full_path" => "c" }])
      end
    end

    assert_equal %w[a b c], build.member_group_paths(token)
    assert_equal [1, 2, 3], token.requests.map { |_p, o| o[:params][:page] }
  end

  def test_member_group_paths_drops_entries_without_a_full_path
    token = FakeToken.new { page([{ "full_path" => "a" }, { "id" => 1 }, { "full_path" => nil }]) }

    assert_equal %w[a], build.member_group_paths(token)
  end

  def test_member_group_paths_accepts_an_empty_membership_list
    token = FakeToken.new { page([]) }

    assert_equal [], build.member_group_paths(token)
  end

  # A server that never stops advertising a next page must not spin forever.
  def test_member_group_paths_raises_past_the_page_cap
    token = FakeToken.new do |_path, opts|
      page([{ "full_path" => "g#{opts[:params][:page]}" }], next_page: opts[:params][:page] + 1)
    end

    err = assert_raises(OAuthClient::Error) { build.member_group_paths(token) }
    assert_match(/too many pages/, err.message)
    assert_equal OAuthClient::MAX_PAGES, token.requests.size
  end

  # MAX_PAGES bounds the number of requests but not wall-clock time: a server
  # answering slowly enough, page after page, parks a Puma thread for minutes.
  # The clock is stubbed, so this asserts the guard without sleeping.
  def test_member_group_paths_raises_once_it_exceeds_its_time_budget
    slow = Class.new(OAuthClient) do
      def initialize(*, **kwargs)
        super
        @ticks = 0
      end

      # First call stamps the deadline, the next one is already past it.
      def monotonic
        @ticks += 1
        @ticks == 1 ? 0.0 : OAuthClient::DEADLINE + 1
      end
    end

    token = FakeToken.new do |_path, opts|
      page([{ "full_path" => "g#{opts[:params][:page]}" }], next_page: opts[:params][:page] + 1)
    end
    client = slow.new(host: HOST, app_id: "app-id", app_secret: "app-secret", redirect_uri: REDIRECT_URI)

    err = assert_raises(OAuthClient::Error) { client.member_group_paths(token) }
    assert_match(/exceeded the #{OAuthClient::DEADLINE}s budget/, err.message)
    assert_empty token.requests, "the budget must be checked before the request, not after"
  end

  def test_member_group_paths_raises_on_a_non_array_body
    [{ "error" => "nope" }, nil, "denied"].each do |body|
      token = FakeToken.new { FakeToken::Response.new(body, {}) }
      err = assert_raises(OAuthClient::Error) { build.member_group_paths(token) }
      assert_match(/group lookup/, err.message)
    end
  end

  # The fail-closed clause of AC3: a failed lookup must never degrade into an
  # empty list, which the caller cannot tell apart from "no memberships".
  def test_member_group_paths_never_swallows_a_transport_failure
    [Faraday::TimeoutError.new("timeout"), OAuth2::Error.new("401"), JSON::ParserError.new("bad json")].each do |boom|
      token = FakeToken.new { raise boom }
      assert_raises(OAuthClient::Error) { build.member_group_paths(token) }
    end
  end

  # A mid-pagination failure must fail the whole lookup, not return the prefix
  # collected so far — a partial list is a fail-open list.
  def test_member_group_paths_fails_rather_than_returning_a_partial_list
    token = FakeToken.new do |_path, opts|
      raise Faraday::TimeoutError, "timeout" if opts[:params][:page] == 2

      page([{ "full_path" => "a" }], next_page: 2)
    end

    assert_raises(OAuthClient::Error) { build.member_group_paths(token) }
  end
end
