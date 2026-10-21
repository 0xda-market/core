# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "rack/mock"
require "zero_x_da/market/catalog/memory_store"
require "zero_x_da/market/catalog/product"
require "zero_x_da/market/catalog/service"
require "zero_x_da/market/denominations/memory_store"
require "zero_x_da/market/denominations/service"
require "zero_x_da/market/identity/admin_service"
require "zero_x_da/market/identity/memory_store"
require "zero_x_da/market/identity/service"
require "zero_x_da/market/transport/json_api"

class DenominationsTest < Minitest::Test
  include KernelFixture

  Denomination = ZeroXDA::Market::Denominations::Denomination
  Price = ZeroXDA::Market::Denominations::Price

  def setup
    @clock = MutableClock.new
    catalog = ZeroXDA::Market::Catalog::Service.new(
      store: ZeroXDA::Market::Catalog::MemoryStore.new(
        products: [
          product("game_special", family: "game_subscription", modes: %w[USDT seeds], position: 1),
          product("game_exclusive", family: "game_subscription", modes: %w[USDT], position: 2),
          product("game_staged", family: "game_subscription", modes: %w[USDT seeds], position: 3, status: "inactive"),
          product("gift_card", family: "gift_card", modes: %w[USDT seeds], position: 4),
          product("tokens", family: "currency", modes: %w[seeds], position: 5, marketable: false)
        ]
      ),
      clock: @clock
    )
    @store = ZeroXDA::Market::Denominations::MemoryStore.new(
      denominations: [
        denomination("seeds", families: %w[game_subscription]),
        denomination("retired", families: %w[game_subscription], status: "inactive")
      ]
    )
    @service = ZeroXDA::Market::Denominations::Service.new(store: @store, catalog: catalog, clock: @clock)

    identity_store = ZeroXDA::Market::Identity::MemoryStore.new
    identity_service = ZeroXDA::Market::Identity::Service.new(
      store: identity_store, clock: @clock, id_generator: SequenceIDs.new
    )
    @administrator = identity_service.authenticate(provider: "identity.example", provider_user_id: "100").user
    @ordinary_user = identity_service.authenticate(provider: "identity.example", provider_user_id: "200").user
    admin_service = ZeroXDA::Market::Identity::AdminService.new(store: identity_store, clock: @clock)
    admin_service.bootstrap(user_id: @administrator.id)

    kernel, = build_kernel(provider: TestProvider.new(clock: @clock), clock: @clock)
    @client = Rack::MockRequest.new(
      ZeroXDA::Market::Transport::JSONAPI.new(
        kernel: kernel,
        identity_service: identity_service,
        admin_service: admin_service,
        catalog: catalog,
        denominations: @service
      )
    )
  end

  def test_denomination_record_rejects_invalid_contracts
    assert_raises(ArgumentError) { denomination("SEEDS") }
    assert_raises(ArgumentError) { denomination("seeds", scale: 7) }
    assert_raises(ArgumentError) { denomination("seeds", symbol: "") }
    assert_raises(ArgumentError) { denomination("seeds", families: ["Game"]) }
  end

  def test_price_amounts_are_exact_integers
    assert_equal "400", price(400).amount_string(0)
    assert_equal "4.00", price(400).amount_string(2)
    assert_equal "0.05", price(5).amount_string(2)
    assert_raises(ArgumentError) { price(0) }
    assert_raises(ArgumentError) { price(1.5) }
    assert_raises(ArgumentError) { price("1.5") }
    assert_raises(ArgumentError) { price(Price::MAX_AMOUNT_MINOR + 1) }
  end

  def test_only_declared_game_goods_can_be_priced
    applied = @service.apply_prices([{ "sku" => "game_special", "amount_minor" => 400 }], denomination: "seeds")
    assert_equal [400], applied.map(&:amount_minor)

    %w[game_exclusive gift_card tokens].each do |sku|
      error = assert_raises(ArgumentError) do
        @service.apply_prices([{ "sku" => sku, "amount_minor" => 1 }], denomination: "seeds")
      end
      assert_match(/not eligible/, error.message)
    end
    assert_equal 1, @service.current_revision
  end

  def test_a_batch_with_one_ineligible_entry_appends_nothing
    assert_raises(ArgumentError) do
      @service.apply_prices(
        [{ "sku" => "game_special", "amount_minor" => 400 }, { "sku" => "gift_card", "amount_minor" => 10 }],
        denomination: "seeds"
      )
    end
    assert_equal 0, @service.current_revision
  end

  def test_inactive_and_unknown_denominations_are_not_found
    %w[retired missing].each do |code|
      assert_raises(ZeroXDA::Market::Core::NotFound) do
        @service.apply_prices([{ "sku" => "game_special", "amount_minor" => 1 }], denomination: code)
      end
    end
    assert_equal %w[seeds], @service.denominations.map(&:code)
  end

  def test_current_prices_hide_staged_products_and_keep_the_latest_row
    @service.apply_prices(
      [{ "sku" => "game_special", "amount_minor" => 400 }, { "sku" => "game_staged", "amount_minor" => 900 }],
      denomination: "seeds"
    )
    @clock.advance(60)
    @service.apply_prices([{ "sku" => "game_special", "amount_minor" => 380 }], denomination: "seeds")

    entries = @service.current_prices(denomination: "seeds").fetch(:entries)
    assert_equal [["game_special", 380]], entries.map { |entry| [entry[:product].sku, entry[:price].amount_minor] }
  end

  def test_stale_revision_is_a_conflict
    @service.apply_prices([{ "sku" => "game_special", "amount_minor" => 400 }], denomination: "seeds")
    assert_raises(ZeroXDA::Market::Core::ConcurrencyConflict) do
      @service.apply_prices(
        [{ "sku" => "game_special", "amount_minor" => 390 }], denomination: "seeds", expected_revision: 0
      )
    end
  end

  def test_public_api_lists_denominations_and_current_prices
    @service.apply_prices([{ "sku" => "game_special", "amount_minor" => 400 }], denomination: "seeds")

    listed = JSON.parse(@client.get("/v1/denominations").body)
    assert_equal ["seeds"], listed.fetch("data").map { |resource| resource.fetch("id") }
    assert_equal(
      { "code" => "seeds", "symbol" => "₴€£", "scale" => 0, "issuer" => "issuer.example",
        "product_families" => ["game_subscription"] },
      listed.dig("data", 0, "attributes")
    )

    response = @client.get("/v1/denominations/seeds/prices?locale=en_US")
    assert_equal 200, response.status, response.body
    document = JSON.parse(response.body)
    assert_equal({ "count" => 1, "denomination" => "seeds", "symbol" => "₴€£", "scale" => 0, "locale" => "en_US" },
                 document.fetch("meta"))
    attributes = document.dig("data", 0, "attributes")
    assert_equal ["game_special", "400", 400, "₴€£"], attributes.values_at("sku", "amount", "amount_minor", "symbol")
    refute attributes.key?("amount_usdt")

    assert_equal 404, @client.get("/v1/denominations/retired/prices").status
  end

  def test_admin_api_appends_prices_and_exposes_history
    applied = request_json(
      "/v1/admin/denomination-prices",
      actor_user_id: @administrator.id, denomination: "seeds", revision: 0,
      prices: [{ sku: "game_special", amount_minor: 400 }]
    )
    assert_equal 201, applied.status, applied.body
    document = JSON.parse(applied.body)
    assert_equal 1, document.dig("meta", "revision")
    assert_equal @administrator.id, document.dig("data", 0, "attributes", "edited_by_user_id")

    ineligible = request_json(
      "/v1/admin/denomination-prices",
      actor_user_id: @administrator.id, denomination: "seeds",
      prices: [{ sku: "gift_card", amount_minor: 10 }]
    )
    assert_equal 422, ineligible.status

    history = JSON.parse(
      @client.get("/v1/admin/denomination-prices/history?actor_user_id=#{@administrator.id}").body
    )
    assert_equal [["1", "denomination_price_history", "400"]],
                 history.fetch("data").map { |row| [row["id"], row["type"], row.dig("attributes", "amount")] }
  end

  def test_admin_api_rejects_non_administrators
    denied = request_json(
      "/v1/admin/denomination-prices",
      actor_user_id: @ordinary_user.id, denomination: "seeds",
      prices: [{ sku: "game_special", amount_minor: 400 }]
    )
    assert_equal 403, denied.status
    assert_equal 403, @client.get("/v1/admin/denomination-prices/history?actor_user_id=#{@ordinary_user.id}").status
    assert_equal 0, @service.current_revision
  end

  private

  def product(sku, family:, modes:, position:, status: "active", marketable: true)
    ZeroXDA::Market::Catalog::Product.new(
      sku: sku, name: sku, button_label: sku, position: position, status: status, marketable: marketable,
      metadata: { "family" => family, "payment_modes" => modes }, created_at: @clock.call
    )
  end

  def denomination(code, symbol: "₴€£", scale: 0, families: %w[game_subscription], status: "active")
    Denomination.new(
      code: code, symbol: symbol, scale: scale, issuer: "issuer.example",
      product_families: families, status: status, created_at: Time.utc(2026, 1, 1)
    )
  end

  def price(amount)
    Price.new(sku: "game_special", denomination: "seeds", amount_minor: amount, source: "core",
              created_at: Time.utc(2026, 1, 1))
  end

  def request_json(path, document)
    @client.post(path, "CONTENT_TYPE" => "application/json", input: JSON.generate(document))
  end
end
