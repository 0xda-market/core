# frozen_string_literal: true

require "uri"

module ZeroXDA
  module Market
    module Adapters
      # Production has its own self-hosted database on edge-prod-1.
      # A misconfigured Supabase/Test URL must never reach production code paths.
      module DatabaseTarget
        ENVIRONMENTS = %w[development production].freeze
        PRODUCTION_HOST = "market-postgres-production"
        PRODUCTION_PORT = 1927
        PRODUCTION_DATABASE = "market"
        PRODUCTION_USER = "market"
        PRODUCTION_LABEL = "#{PRODUCTION_HOST}:#{PRODUCTION_PORT}/#{PRODUCTION_DATABASE}".freeze

        # libpq reads these even when Sequel passes host/port/dbname explicitly
        # (hostaddr and service files can redirect the effective connection).
        LIBPQ_OVERRIDES = %w[PGHOSTADDR PGSERVICE PGSERVICEFILE PGSYSCONFDIR].freeze

        class InvalidTarget < StandardError; end

        module_function

        def verify!(url, environment: ENV.fetch("DEPLOY_ENV", "development"), env: ENV)
          raise InvalidTarget, "unsupported deployment environment" unless ENVIRONMENTS.include?(environment)
          return unless environment == "production"

          raise InvalidTarget, "production DATABASE_URL is required" unless url.is_a?(String) && !url.empty?
          raise InvalidTarget, "production DATABASE_URL must target the self-hosted #{PRODUCTION_LABEL}" unless production_url?(url)

          overrides = LIBPQ_OVERRIDES.reject { |name| env[name].to_s.empty? }
          raise InvalidTarget, "production database target may not be overridden by #{overrides.join(", ")}" unless overrides.empty?
        end

        # Sequel lets URI query parameters (host, port, database, user, conn_str...)
        # override the authority and path, so only a bare URL (no query, no "#" suffix) is allowed.
        def production_url?(url)
          uri = URI.parse(url)
          %w[postgres postgresql].include?(uri.scheme) &&
            uri.query.nil? &&
            !url.include?("#") &&
            uri.host == PRODUCTION_HOST &&
            uri.port == PRODUCTION_PORT &&
            uri.path == "/#{PRODUCTION_DATABASE}" &&
            uri.user == PRODUCTION_USER &&
            !uri.password.to_s.empty?
        rescue URI::Error
          false
        end
      end
    end
  end
end
