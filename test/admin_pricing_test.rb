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
require "zero_x_da/market/pricing/memory_store"
require "zero_x_da/market/pricing/service"
require "zero_x_da/market/transport/json_api"

class AdminPricingTest < Minitest::Test
  include KernelFixture

  def setup
    @clock = MutableClock.new
    product = ZeroXDA::Market::Catalog::Product.new(
      sku: "premium_3m",
      short_name: "Premium 3m",
      name: "Telegram Premium 3 months",
      button_label: "Premium 3m",
      metadata: { "family" => "telegram_premium", "duration_months" => 3 },
      position: 1,
      created_at: @clock.call
    )
    catalog = ZeroXDA::Market::Catalog::Service.new(
      store: ZeroXDA::Market::Catalog::MemoryStore.new(products: [product]),
      clock: @clock
    )
    @pricing = ZeroXDA::Market::Pricing::Service.new(
      store: ZeroXDA::Market::Pricing::MemoryStore.new,
      catalog: catalog,
      clock: @clock
    )

    identity_store = ZeroXDA::Market::Identity::MemoryStore.new
    identity_service = ZeroXDA::Market::Identity::Service.new(
      store: identity_store,
      clock: @clock,
      id_generator: SequenceIDs.new
    )
    @administrator = identity_service.authenticate(
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
    admin_service.bootstrap(user_id: @administrator.id)

    provider = TestProvider.new(clock: @clock)
    kernel, = build_kernel(provider: provider, clock: @clock)
    @client = Rack::MockRequest.new(
      ZeroXDA::Market::Transport::JSONAPI.new(
        kernel: kernel,
        identity_service: identity_service,
        admin_service: admin_service,
        catalog: catalog,
        pricing: @pricing
      )
    )
    @ordinary_user = ordinary_user
  end

  def test_applies_one_revisioned_batch_and_exposes_append_only_history
    proposal = @client.get(
      "/v1/admin/prices/proposal?actor_user_id=#{@administrator.id}&locale=en_US"
    )
    assert_equal 200, proposal.status, proposal.body
    assert_equal 0, JSON.parse(proposal.body).dig("meta", "revision")

    applied = request_json(
      "/v1/admin/prices",
      actor_user_id: @administrator.id,
      revision: 0,
      prices: [{ sku: "premium_3m", amount_usdt: "12.50" }]
    )
    assert_equal 201, applied.status, applied.body
    document = JSON.parse(applied.body)
    assert_equal "ok", document.fetch("status")
    assert_equal 1, document.dig("meta", "revision")
    assert_equal "12.5", document.dig("data", 0, "attributes", "amount_usdt")

    history = @client.get(
      "/v1/admin/prices/history?actor_user_id=#{@administrator.id}&limit=10"
    )
    assert_equal 200, history.status, history.body
    history_document = JSON.parse(history.body)
    assert_equal 1, history_document.dig("meta", "revision")
    assert_equal "1", history_document.dig("data", 0, "id")
    assert_equal @administrator.id,
                 history_document.dig("data", 0, "attributes", "edited_by_user_id")
  end

  def test_rejects_a_stale_application_without_appending_any_price
    request_json(
      "/v1/admin/prices",
      actor_user_id: @administrator.id,
      revision: 0,
      prices: [{ sku: "premium_3m", amount_usdt: "12.50" }]
    )

    stale = request_json(
      "/v1/admin/prices",
      actor_user_id: @administrator.id,
      revision: 0,
      prices: [{ sku: "premium_3m", amount_usdt: "11.90" }]
    )
    assert_equal 409, stale.status, stale.body
    assert_equal "concurrency_conflict", JSON.parse(stale.body).dig("errors", 0, "code")
    assert_equal 1, @pricing.history.length
  end

  def test_denies_price_history_to_a_non_administrator
    response = @client.get(
      "/v1/admin/prices/history?actor_user_id=#{@ordinary_user.id}"
    )
    assert_equal 403, response.status
  end

  private

  def request_json(path, document)
    @client.post(
      path,
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(document)
    )
  end
end
