# frozen_string_literal: true

require_relative "test_helper"
require "securerandom"
require "zero_x_da/market/adapters/postgres_database"
require "zero_x_da/market/adapters/postgres_migrator"
require "zero_x_da/market/identity/postgres_store"
require "zero_x_da/market/identity/service"

class PostgresExternalIdentityLookupTest < Minitest::Test
  def setup
    database_url = ENV["TEST_DATABASE_URL"]
    skip "TEST_DATABASE_URL is not configured" if database_url.to_s.empty?

    @database = ZeroXDA::Market::Adapters::PostgresDatabase.new(
      url: database_url,
      max_connections: 1
    )
    ZeroXDA::Market::Adapters::PostgresMigrator.new(
      database: @database,
      path: File.expand_path("../db/migrations", __dir__)
    ).migrate!
    @service = ZeroXDA::Market::Identity::Service.new(
      store: ZeroXDA::Market::Identity::PostgresStore.new(database: @database)
    )
  end

  def teardown
    @database&.disconnect
  end

  def test_finds_provider_data_case_insensitively_in_postgresql
    suffix = SecureRandom.hex(8)
    authentication = @service.authenticate(
      provider: "telegram",
      provider_user_id: "lookup-#{suffix}",
      provider_data: { username: "Target_#{suffix}" }
    )

    profile = @service.find_profile_by_external_identity(
      provider: "telegram",
      provider_data_key: "username",
      provider_data_value: "target_#{suffix}",
      case_insensitive: true
    )

    assert_equal authentication.user.id, profile.user.id
    assert_equal "lookup-#{suffix}", profile.identities.first.provider_user_id
  end
end
