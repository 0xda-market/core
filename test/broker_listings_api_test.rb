# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "rack/mock"
require "zero_x_da/market/catalog/memory_store"
require "zero_x_da/market/catalog/product"
require "zero_x_da/market/catalog/service"
require "zero_x_da/market/identity/memory_store"
require "zero_x_da/market/identity/service"
require "zero_x_da/market/listings/memory_store"
require "zero_x_da/market/listings/service"
require "zero_x_da/market/transport/json_api"

class BrokerListingsAPITest < Minitest::Test
  include KernelFixture

  def setup
    clock = MutableClock.new
    provider = TestProvider.new(clock: clock)
    kernel, = build_kernel(provider: provider, clock: clock)
    users = ZeroXDA::Market::Identity::MemoryStore.new
    identity = ZeroXDA::Market::Identity::Service.new(
      store: users,
      clock: clock,
      id_generator: SequenceIDs.new
    )
    @broker = identity.authenticate(provider: "telegram", provider_user_id: 77, role: "broker").user
    products = [
      product("ton", true, 1, {}, clock),
      product("usdt", false, 100, { family: "currency", code: "USDT" }, clock)
    ]
    catalog = ZeroXDA::Market::Catalog::Service.new(
      store: ZeroXDA::Market::Catalog::MemoryStore.new(products: products)
    )
    listings = ZeroXDA::Market::Listings::Service.new(
      store: ZeroXDA::Market::Listings::MemoryStore.new,
      users: users,
      catalog: catalog,
      clock: clock,
      id_generator: SequenceIDs.new
    )
    @client = Rack::MockRequest.new(
      ZeroXDA::Market::Transport::JSONAPI.new(kernel: kernel, listings: listings)
    )
  end

  def test_broker_listing_http_lifecycle_preserves_exact_decimals
    created = resource(post("/v1/broker/listings", {
      actor_user_id: @broker.id,
      sku: "ton",
      quantity: "12.500000000001",
      price_amount: "3.12345678",
      currency: "USDT"
    }), 201)

    assert_equal "12.500000000001", created.dig("attributes", "quantity")
    assert_equal "3.12345678", created.dig("attributes", "price_amount")

    listed = JSON.parse(@client.get(
      "/v1/broker/listings?actor_user_id=#{@broker.id}"
    ).body)
    assert_equal [created.fetch("id")], listed.fetch("data").map { |entry| entry.fetch("id") }

    updated = resource(patch("/v1/broker/listings/#{created.fetch("id")}", {
      actor_user_id: @broker.id,
      quantity: "13",
      price_amount: "3.20",
      currency: "USDT",
      version: 0
    }), 200)
    assert_equal 1, updated.dig("attributes", "version")

    withdrawn = resource(delete("/v1/broker/listings/#{created.fetch("id")}", {
      actor_user_id: @broker.id,
      version: 1
    }), 200)
    assert_equal "withdrawn", withdrawn.dig("attributes", "status")
  end

  private

  def product(sku, marketable, position, metadata, clock)
    ZeroXDA::Market::Catalog::Product.new(
      sku: sku,
      short_name: sku.upcase,
      name: sku.upcase,
      button_label: sku.upcase,
      metadata: metadata,
      marketable: marketable,
      position: position,
      created_at: clock.call
    )
  end

  def post(path, body)
    request("POST", path, body)
  end

  def patch(path, body)
    request("PATCH", path, body)
  end

  def delete(path, body)
    request("DELETE", path, body)
  end

  def request(method, path, body)
    @client.request(
      method,
      path,
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(body)
    )
  end

  def resource(response, status)
    assert_equal status, response.status, response.body
    JSON.parse(response.body).fetch("data")
  end
end
