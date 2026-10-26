# frozen_string_literal: true

require_relative "test_helper"
require "bigdecimal"
require "zero_x_da/market/adapters/postgres_database"
require "zero_x_da/market/adapters/postgres_migrator"
require "zero_x_da/market/catalog/postgres_store"
require "zero_x_da/market/catalog/service"

class Ox1SubscriptionCatalogTest < Minitest::Test
  PRICES = {
    "special" => {
      1 => ["2.49", 400], 3 => ["6.29", 1020],
      6 => ["11.49", 1800], 12 => ["14.99", 2400]
    },
    "exclusive" => {
      1 => ["5.49", nil], 3 => ["13.99", nil],
      6 => ["24.49", nil], 12 => ["32.99", nil]
    }
  }.freeze

  def setup
    skip "TEST_DATABASE_URL is not configured" unless ENV["TEST_DATABASE_URL"]

    @database = ZeroXDA::Market::Adapters::PostgresDatabase.new(
      url: ENV.fetch("TEST_DATABASE_URL"), max_connections: 2
    )
    migrate
    @store = ZeroXDA::Market::Catalog::PostgresStore.new(database: @database)
    @catalog = ZeroXDA::Market::Catalog::Service.new(store: @store)
  end

  def teardown
    @database&.disconnect
  end

  def test_eight_durations_have_exact_prices_and_payment_contracts
    PRICES.each do |tier, durations|
      durations.each do |months, (usdt, seeds)|
        sku = "0x1_#{tier}_#{months}m"
        product = @catalog.find_product(sku)
        assert_equal "inactive", product.status, sku
        assert product.marketable?, sku
        assert_equal "0x1_subscription", product.metadata.fetch("family"), sku
        assert_equal({ "kind" => "system_broker", "id" => "0x1", "issuer" => "0x1" },
                     product.supplier, sku)
        assert product.system_broker?, sku
        assert_equal tier, product.metadata.fetch("tier"), sku
        assert_equal months, product.metadata.fetch("duration_months"), sku
        assert_equal "single", product.metadata.dig("purchase", "quantity_mode"), sku
        assert_equal "not_configured", product.metadata.dig("purchase", "fulfillment"), sku
        assert_equal "0x1", product.metadata.dig("purchase", "recipient", "provider"), sku
        assert_equal ["self"], product.metadata.dig("purchase", "recipient", "modes"), sku

        modes = product.metadata.fetch("payment_modes")
        assert_equal(seeds ? %w[USDT seeds] : %w[USDT], modes, sku)
        if seeds
          assert_equal(
            { "amount" => seeds, "currency" => "seeds", "symbol" => "₴€£" },
            product.metadata.fetch("seed_price"), sku
          )
        else
          refute product.metadata.key?("seed_price"), sku
        end

        history = @database.connection[Sequel.qualify(:market, :product_prices)]
                           .where(sku: sku).order(Sequel.desc(:id)).all
        assert_equal 1, history.size, sku
        assert_equal BigDecimal(usdt), BigDecimal(history.first.fetch(:amount_usdt).to_s), sku
        assert_equal "core", history.first.fetch(:source), sku
        assert_equal BigDecimal(usdt), product.current_price_usdt, sku
      end
    end
  end

  def test_localizations_and_safe_unavailability
    refute @catalog.products.any? { |product| product.sku.start_with?("0x1_") }
    assert_equal 8, @catalog.admin_products.count { |product| product.sku.start_with?("0x1_") }

    english = @catalog.find_product("0x1_special_1m")
    assert_equal "0x1 Special Sub — 1 month", english.name

    ukrainian = @catalog.find_product("0x1_special_3m", locale: "uk_UA")
    assert_equal "Підписка 0x1 Special на 3 місяці", ukrainian.name

    russian = @catalog.find_product("0x1_exclusive_12m", locale: "ru_RU")
    assert_equal "Подписка 0x1 Exclusive на 12 месяцев", russian.name

    fallback = @catalog.find_product("0x1_exclusive_1m", locale: "de_DE")
    assert_equal "en_US", fallback.locale
  end

  def test_migration_is_replay_safe_and_preserves_prices
    prices = @database.connection[Sequel.qualify(:market, :product_prices)]
    before = prices.where(sku: "0x1_special_1m").count
    migrate
    assert_equal before, prices.where(sku: "0x1_special_1m").count
  end

  private

  def migrate
    ZeroXDA::Market::Adapters::PostgresMigrator.new(
      database: @database,
      path: File.expand_path("../db/migrations", __dir__)
    ).migrate!
  end
end
