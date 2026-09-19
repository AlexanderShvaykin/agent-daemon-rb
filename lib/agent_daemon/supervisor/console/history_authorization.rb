# frozen_string_literal: true

require "rack"

require_relative "auth"

module AgentDaemon
  module Supervisor
    module Console
      # Re-checks GitLab group membership on every persisted-history request
      # (Story 5.5). Sits between Auth and App.
      #
      # Auth re-validates membership only when something calls the lambda it
      # puts in env[Auth::AUTHORIZATION_ENV_KEY], and until now only the SSE
      # stream did. The fleet and entity pages carry that stream; the history
      # pages are static snapshots and carry none, so without this a revoked
      # operator could keep reading persisted output until session_ttl.
      # Calling the lambda here keeps access-control code out of App and
      # leaves Auth unchanged. The lambda itself rate-limits the GitLab round
      # trip to once per Auth::GROUP_RECHECK_INTERVAL, and a failed check has
      # already deleted the session by the time it returns.
      #
      # Every other path passes straight through without calling the lambda.
      class HistoryAuthorization
        PREFIX = "/history"

        def initialize(app)
          @app = app
        end

        def call(env)
          return @app.call(env) unless history_path?(env["PATH_INFO"].to_s)
          return denied(env) unless authorized?(env[Auth::AUTHORIZATION_ENV_KEY])

          @app.call(env)
        end

        private

        def history_path?(path)
          path == PREFIX || path.start_with?("#{PREFIX}/")
        end

        # Anything but a literal true is a denial, and so is a check that
        # raises: failing closed is the point.
        def authorized?(check)
          check.respond_to?(:call) && check.call == true
        rescue StandardError
          false
        end

        # Back to the same history page after re-login, as Auth does. The path
        # always starts with /history here, so it is a local return target.
        def denied(env)
          fullpath = Rack::Request.new(env).fullpath
          [302, { "content-type" => "text/plain; charset=utf-8",
                  "location" => "#{Auth::LOGIN_PATH}?return_to=#{Rack::Utils.escape(fullpath)}" }, []]
        end
      end
    end
  end
end
