# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/adapters/postgres_database"
require "zero_x_da/market/adapters/postgres_migrator"

class CatalogMigrationRecoveryTest < Minitest::Test
  DATABASE_URL = ENV["TEST_DATABASE_URL"]
  BUYER_SKUS = %w[
    premium_3m premium_6m premium_9m
    stars_500 stars_1000 stars_3000
  ].freeze

  def setup
    skip "TEST_DATABASE_URL is not configured" unless DATABASE_URL

    @database = ZeroXDA::Market::Adapters::PostgresDatabase.new(
      url: DATABASE_URL,
      max_connections: 2
    )
    migrate!
  end

  def teardown
    @database&.disconnect
  end

  def test_recipient_catalog_migration_recovers_a_partially_cleared_catalog
    connection = @database.connection

    connection[Sequel.qualify(:market, :products)]
      .where(sku: BUYER_SKUS)
      .delete
    connection[Sequel.qualify(:market, :schema_migrations)]
      .where(version: "018_catalog_recipient_contract")
      .delete

    migrate!

    products = connection[Sequel.qualify(:market, :products)]
      .where(sku: BUYER_SKUS)
      .order(:position)
      .all
    assert_equal BUYER_SKUS, products.map { |row| row.fetch(:sku) }
    assert_equal [1, 2, 3, 4, 5, 6], products.map { |row| row.fetch(:position) }
    assert products.all? { |row| row.fetch(:status) == "active" && row.fetch(:marketable) }

    localizations = connection[Sequel.qualify(:market, :product_localizations)]
      .where(product_sku: BUYER_SKUS)
      .all
    assert_equal 18, localizations.length
    assert_equal %w[en_US ru_RU uk_UA], localizations.map { |row| row.fetch(:locale) }.uniq.sort

    versions = connection[Sequel.qualify(:market, :schema_migrations)].select_map(:version)
    assert_includes versions, "018_catalog_recipient_contract"
  end

  private

  def migrate!
    ZeroXDA::Market::Adapters::PostgresMigrator.new(
      database: @database,
      path: File.expand_path("../db/migrations", __dir__)
    ).migrate!
  end
end
