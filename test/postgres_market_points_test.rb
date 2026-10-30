# frozen_string_literal: true
# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT

require_relative "test_helper"
require "zero_x_da/market/adapters/postgres_database"
require "zero_x_da/market/adapters/postgres_migrator"
require "zero_x_da/market/points/postgres_store"
require "zero_x_da/market/points/service"

class PostgresMarketPointsTest < Minitest::Test
  def setup
    skip "TEST_DATABASE_URL is not configured" unless ENV["TEST_DATABASE_URL"]

    @database = ZeroXDA::Market::Adapters::PostgresDatabase.new(url: ENV.fetch("TEST_DATABASE_URL"), max_connections: 2)
    ZeroXDA::Market::Adapters::PostgresMigrator.new(
      database: @database, path: File.expand_path("../db/migrations", __dir__)
    ).migrate!
    @points = ZeroXDA::Market::Points::Service.new(
      store: ZeroXDA::Market::Points::PostgresStore.new(database: @database)
    )
  end

  def teardown
    @database&.disconnect
  end

  def test_seeded_kyiv_points_have_unique_addresses
    all = @points.all
    assert_equal 22, all.length
    assert_equal all.map(&:address).uniq, all.map(&:address)
    assert_equal "0xda-market-zoloti-vorota", @points.resolve("zoloti").point.station_pub_dress
    assert_equal ["zoloti", false], [@points.resolve("золоті").point.address, @points.resolve("золоті").canonical]
    assert_equal "zoloti", @points.address_for(owner_pub_dress: "0xda-market", point: "zoloti-vorota")
    assert_equal "tsum", @points.address_for(owner_pub_dress: "0xda-market", point: "tsum")
  end

  def test_addresses_and_aliases_are_constrained
    points = @database.connection[Sequel.qualify(:market, :point_addresses)]
    aliases = @database.connection[Sequel.qualify(:market, :point_address_aliases)]
    [{ address: "Zoloti" }, { address: "zo/loti" }, { address: "-zoloti" }].each do |row|
      assert_raises(Sequel::CheckConstraintViolation, row.inspect) do
        @database.connection.transaction(savepoint: true) do
          points.insert({ owner_pub_dress: "0xda-market", place: "new-place" }.merge(row))
        end
      end
    end
    assert_raises(Sequel::UniqueConstraintViolation) do
      @database.connection.transaction(savepoint: true) do
        points.insert(address: "zoloti-2", owner_pub_dress: "0xda-market", place: "zoloti-vorota")
      end
    end
    [{ alias: "a b", address: "zoloti" }, { alias: "x/y", address: "zoloti" }].each do |row|
      assert_raises(Sequel::CheckConstraintViolation, row.inspect) do
        @database.connection.transaction(savepoint: true) { aliases.insert(row) }
      end
    end
    assert_raises(Sequel::ForeignKeyConstraintViolation) do
      @database.connection.transaction(savepoint: true) { aliases.insert(alias: "old", address: "missing") }
    end
  end
end
