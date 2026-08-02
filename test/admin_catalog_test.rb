# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "rack/mock"
require "zero_x_da/market/catalog/memory_store"
require "zero_x_da/market/catalog/product"
require "zero_x_da/market/catalog/service"
require "zero_x_da/market/identity/admin_service"
require "zero_x_da/market/identity/memory_store"
require "zero_x_da/market/identity/service"
require "zero_x_da/market/transport/json_api"

class AdminCatalogTest < Minitest::Test
  include KernelFixture

  def setup
    @clock = MutableClock.new
    @product = ZeroXDA::Market::Catalog::Product.new(
      sku: "premium_3m",
      short_name: "Premium 3m",
      name: "Telegram Premium 3 months",
      button_label: "Premium 3m",
      metadata: { "family" => "telegram_premium", "duration_months" => 3 },
      position: 1,
      created_at: @clock.call
    )
    @store = ZeroXDA::Market::Catalog::MemoryStore.new(products: [@product])
    @catalog = ZeroXDA::Market::Catalog::Service.new(store: @store, clock: @clock)
  end

  def test_updates_neutral_product_state_and_localizations_with_versions
    @clock.advance(10)
    updated = @catalog.update_product(
      sku: "premium_3m",
      actor_user_id: "admin-1",
      expected_version: 0,
      attributes: {
        "short_name" => "Premium quarter",
        "status" => "inactive",
        "position" => 4,
        "marketable" => false,
        "metadata" => { "family" => "telegram_premium", "duration_months" => 3 }
      }
    )

    assert_equal 1, updated.version
    assert_equal "admin-1", updated.updated_by_user_id
    assert_equal "Premium quarter", updated.short_name
    assert_equal "inactive", updated.status
    refute updated.marketable?
    assert_empty @catalog.products
    assert_equal ["premium_3m"], @catalog.admin_products.map(&:sku)

    assert_raises(ZeroXDA::Market::Core::ConcurrencyConflict) do
      @catalog.update_product(
        sku: "premium_3m",
        actor_user_id: "admin-1",
        expected_version: 0,
        attributes: { "position" => 5 }
      )
    end

    ukrainian = @catalog.save_localization(
      sku: "premium_3m",
      locale: "uk_UA",
      full_name: "Telegram Premium 3 місяці",
      button_label: "Premium 3 міс.",
      actor_user_id: "admin-1"
    )
    assert_equal 0, ukrainian.version
    assert_equal "Telegram Premium 3 місяці", @catalog.find_product("premium_3m", locale: "uk_UA").name

    @clock.advance(10)
    revised = @catalog.save_localization(
      sku: "premium_3m",
      locale: "uk_UA",
      full_name: "Telegram Premium на 3 місяці",
      button_label: "Premium · 3 міс.",
      actor_user_id: "admin-1",
      expected_version: 0
    )
    assert_equal 1, revised.version

    assert_raises(ZeroXDA::Market::Core::ConcurrencyConflict) do
      @catalog.save_localization(
        sku: "premium_3m",
        locale: "uk_UA",
        full_name: "Stale",
        button_label: "Stale",
        actor_user_id: "admin-1",
        expected_version: 0
      )
    end
  end

  def test_admin_api_lists_and_updates_products_without_trusting_the_browser_role
    identity_store = ZeroXDA::Market::Identity::MemoryStore.new
    identity_service = ZeroXDA::Market::Identity::Service.new(
      store: identity_store,
      clock: @clock,
      id_generator: SequenceIDs.new
    )
    administrator = identity_service.authenticate(
      provider: "telegram",
      provider_user_id: "100"
    ).user
    ordinary_user = identity_service.authenticate(
      provider: "telegram",
      provider_user_id: "200"
    ).user
    admin_service = ZeroXDA::Market::Identity::AdminService.new(
      store: identity_store,
      clock: @clock
    )
    admin_service.bootstrap(user_id: administrator.id)

    provider = TestProvider.new(clock: @clock)
    kernel, = build_kernel(provider: provider, clock: @clock)
    client = Rack::MockRequest.new(
      ZeroXDA::Market::Transport::JSONAPI.new(
        kernel: kernel,
        identity_service: identity_service,
        admin_service: admin_service,
        catalog: @catalog
      )
    )

    forbidden = client.get("/v1/admin/products?actor_user_id=#{ordinary_user.id}")
    assert_equal 403, forbidden.status

    listing = client.get("/v1/admin/products?actor_user_id=#{administrator.id}&locale=en_US")
    assert_equal 200, listing.status, listing.body
    document = JSON.parse(listing.body)
    assert_equal 1, document.dig("meta", "count")
    assert_equal 0, document.dig("data", 0, "attributes", "version")
    assert_equal ["en_US"], document.dig("data", 0, "attributes", "localizations").map do |entry|
      entry.dig("attributes", "locale")
    end

    update = request_json(
      client,
      "PATCH",
      "/v1/admin/products/premium_3m",
      actor_user_id: administrator.id,
      version: 0,
      attributes: { short_name: "Premium · 3m", position: 2 }
    )
    assert_equal 200, update.status, update.body
    assert_equal "Premium · 3m", JSON.parse(update.body).dig("data", "attributes", "short_name")

    localization = request_json(
      client,
      "PUT",
      "/v1/admin/products/premium_3m/localizations/uk_UA",
      actor_user_id: administrator.id,
      full_name: "Telegram Premium на 3 місяці",
      button_label: "Premium · 3 міс."
    )
    assert_equal 201, localization.status, localization.body
    assert_equal "uk_UA", JSON.parse(localization.body).dig("data", "attributes", "locale")
  end

  private

  def request_json(client, method, path, document)
    client.request(
      method,
      path,
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(document)
    )
  end
end
