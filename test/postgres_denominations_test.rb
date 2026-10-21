# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/adapters/postgres_database"
require "zero_x_da/market/adapters/postgres_migrator"
require "zero_x_da/market/catalog/postgres_store"
require "zero_x_da/market/catalog/service"
require "zero_x_da/market/denominations/postgres_store"
require "zero_x_da/market/denominations/service"

class PostgresDenominationsTest < Minitest::Test
  SPECIAL_SEEDS = {
    "0x1_special_1m" => 400, "0x1_special_3m" => 1020,
    "0x1_special_6m" => 1800, "0x1_special_12m" => 2400
  }.freeze

  def setup
    skip "TEST_DATABASE_URL is not configured" unless ENV["TEST_DATABASE_URL"]

    @database = ZeroXDA::Market::Adapters::PostgresDatabase.new(
      url: ENV.fetch("TEST_DATABASE_URL"), max_connections: 2
    )
    ZeroXDA::Market::Adapters::PostgresMigrator.new(
      database: @database, path: File.expand_path("../db/migrations", __dir__)
    ).migrate!
    @connection = @database.connection
    @store = ZeroXDA::Market::Denominations::PostgresStore.new(database: @database)
    catalog = ZeroXDA::Market::Catalog::Service.new(
      store: ZeroXDA::Market::Catalog::PostgresStore.new(database: @database)
    )
    @service = ZeroXDA::Market::Denominations::Service.new(store: @store, catalog: catalog)
  end

  def teardown
    @database&.disconnect
  end

  def test_seeds_is_a_whole_unit_game_denomination_outside_fiat_fx
    seeds = @store.find_denomination("seeds")
    assert_equal ["₴€£", 0, "0x1", "active", ["0x1_subscription"]],
                 [seeds.symbol, seeds.scale, seeds.issuer, seeds.status, seeds.product_families]
    assert_empty @connection[Sequel.qualify(:market, :products)].where(sku: %w[seeds seed SEED]).all
    assert_empty @connection[Sequel.qualify(:market, :product_prices)].where(sku: "seeds").all
  end

  def test_staged_seed_prices_are_carried_without_touching_catalog_metadata
    first_rows = @connection[Sequel.qualify(:market, :denomination_prices)]
      .where(denomination: "seeds", source: "core")
      .order(:id).all
      .uniq { |row| row.fetch(:sku) }
    assert_equal SPECIAL_SEEDS, first_rows.to_h { |row| [row.fetch(:sku), row.fetch(:amount_minor)] }

    SPECIAL_SEEDS.each do |sku, amount|
      metadata = @connection[Sequel.qualify(:market, :products)].where(sku: sku).get(:metadata)
      assert_equal({ "amount" => amount, "currency" => "seeds", "symbol" => "₴€£" }, metadata["seed_price"].to_h)
    end
  end

  def test_staged_products_have_no_public_seed_prices
    assert_empty @service.current_prices(denomination: "seeds").fetch(:entries)
  end

  def test_database_rejects_ineligible_goods_and_history_rewrites
    prices = @connection[Sequel.qualify(:market, :denomination_prices)]
    %w[0x1_exclusive_1m premium_3m usdt].each do |sku|
      assert_raises(Sequel::CheckConstraintViolation, sku) do
        @connection.transaction(rollback: :always, savepoint: true) do
          prices.insert(sku: sku, denomination: "seeds", amount_minor: 1, source: "admin")
        end
      end
    end
    assert_raises(Sequel::DatabaseError) do
      @connection.transaction(rollback: :always, savepoint: true) do
        prices.where(denomination: "seeds").update(amount_minor: 1)
      end
    end
    assert_raises(Sequel::DatabaseError) do
      @connection.transaction(rollback: :always, savepoint: true) { prices.where(denomination: "seeds").delete }
    end
  end

  def test_deleting_an_editor_keeps_the_price_and_clears_only_the_editor
    @connection.transaction(rollback: :always) do
      users = @connection[Sequel.qualify(:market, :users)]
      editor_id = users.returning(:id).insert(role: "admin", status: "active").first.fetch(:id)
      price = @service.apply_prices(
        [{ "sku" => "0x1_special_3m", "amount_minor" => 1000 }], denomination: "seeds", set_by_user_id: editor_id
      ).first

      users.where(id: editor_id).delete

      row = @connection[Sequel.qualify(:market, :denomination_prices)].where(id: price.id).first
      assert_nil row.fetch(:set_by_user_id)
      assert_equal 1000, row.fetch(:amount_minor)
    end
  end

  def test_store_appends_and_reads_the_latest_price
    @connection.transaction(rollback: :always) do
      revision = @store.revision
      appended = @service.apply_prices(
        [{ "sku" => "0x1_special_1m", "amount_minor" => 380 }], denomination: "seeds", expected_revision: revision
      )
      assert_equal 380, @store.latest_prices(denomination: "seeds").fetch("0x1_special_1m").amount_minor
      assert_equal appended.first.id, @store.history(limit: 1).first.id
      assert_raises(ZeroXDA::Market::Core::ConcurrencyConflict) do
        @service.apply_prices(
          [{ "sku" => "0x1_special_1m", "amount_minor" => 370 }], denomination: "seeds", expected_revision: revision
        )
      end
    end
  end
end
