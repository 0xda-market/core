# frozen_string_literal: true
# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT

require_relative "test_helper"
require "rack/mock"
require "json"
require "zero_x_da/market/catalog/memory_store"
require "zero_x_da/market/catalog/service"
require "zero_x_da/market/denominations/memory_store"
require "zero_x_da/market/denominations/service"
require "zero_x_da/market/identity/memory_store"
require "zero_x_da/market/identity/service"
require "zero_x_da/market/issuer_orders/memory_store"
require "zero_x_da/market/issuer_orders/memory_directory"
require "zero_x_da/market/issuer_orders/service"
require "zero_x_da/market/transport/nilx_browser_api"
require "zero_x_da/market/transport/issuer_api"

class NilxSeedsCheckoutTest < Minitest::Test
  M = ZeroXDA::Market
  class Sessions
    def initialize
      @rows = {}
    end
    def put(key, kind, value, expiry)
      @rows[[key, kind]] = [value, expiry]
    end
    def read(key, kind, now)
      row = @rows[[key, kind]]
      row && row.last > now ? row.first : nil
    end
    def consume(key, kind, now)
      row = read(key, kind, now)
      @rows.delete([key, kind])
      row
    end
  end

  def setup
    @now = Time.utc(2026, 10, 28)
    @users = M::Identity::MemoryStore.new
    identities = M::Identity::Service.new(store: @users, clock: -> { @now })
    metadata = { "family" => "0x1_subscription", "payment_modes" => ["seeds"],
      "purchase" => { "recipient" => { "provider" => "0x1", "modes" => ["self"] } },
      "supplier" => { "kind" => "system_broker", "id" => "0x1", "issuer" => "0x1" } }
    products = ["0x1_special_1m", "0x1_special_3m", "0x1_exclusive_1m"].map.with_index do |sku, index|
      M::Catalog::Product.new(sku: sku, name: sku, button_label: sku, locale: "en_US", position: index,
        status: index == 1 ? "inactive" : "active",
        metadata: metadata.merge("duration_months" => sku[/_(\d+)m\z/, 1].to_i), created_at: @now)
    end
    catalog = M::Catalog::Service.new(store: M::Catalog::MemoryStore.new(products: products))
    denominations = M::Denominations::MemoryStore.new(denominations: [
      M::Denominations::Denomination.new(code: "seeds", symbol: "₴€£", scale: 0,
        issuer: "0x1", product_families: ["0x1_subscription"], created_at: @now)
    ])
    @prices = M::Denominations::Service.new(store: denominations, catalog: catalog, clock: -> { @now })
    @prices.apply_prices([{ "sku" => "0x1_special_1m", "amount_minor" => 640 },
      { "sku" => "0x1_special_3m", "amount_minor" => 1632 }], denomination: "seeds")
    @orders = M::IssuerOrders::Service.new(store: M::IssuerOrders::MemoryStore.new,
      denominations: @prices, users: @users, directory: M::IssuerOrders::MemoryDirectory.new(available: false),
      clock: -> { @now })
    @app = M::Transport::NilxBrowserAPI.new(store: Sessions.new, identity_service: identities,
      token: "h" * 32, clock: -> { @now.to_i }, issuer_orders: @orders, denominations: @prices)
    @client = Rack::MockRequest.new(@app)
    @cookie = login("a", "0x0sky", "v")
    @other_cookie = login("b", "0x0other", "w")
    @offer = JSON.parse(@client.get("/offers", "HTTP_COOKIE" => @cookie).body).fetch("offers").first
    @purchase = @offer.slice("sku", "price_id", "amount_minor").merge("idempotency_key" => "purchase-key-0001")
  end

  def login(subject, recipient, visit)
    issued = @client.post("/handoffs", "HTTP_AUTHORIZATION" => "Bearer #{'h' * 32}",
      input: JSON.generate(subject: subject * 64, point: "золоті", seeds: "1000", seeds_authority: "identity_snapshot",
        avaia: { longitude: 30.5, latitude: 50.4 }, visit_id: visit * 43, recipient: recipient, return_path: "/telegram/"))
    assert_equal 201, issued.status
    accepted = @client.post("/exchange", "HTTP_ORIGIN" => M::Transport::NilxBrowserAPI::SOURCE,
      "CONTENT_TYPE" => "application/x-www-form-urlencoded", input: "code=#{JSON.parse(issued.body).fetch('code')}")
    assert_equal 303, accepted.status
    accepted["set-cookie"].split(";").first
  end

  def post(path = "/orders", body = @purchase, cookie = @cookie, **headers)
    @client.post(path, { "HTTP_COOKIE" => cookie, "HTTP_ORIGIN" => M::Transport::NilxBrowserAPI::TARGET,
      "HTTP_X_MARKET_CSRF" => "1", "CONTENT_TYPE" => "application/json", input: JSON.generate(body) }.merge(headers))
  end

  def test_only_active_special_seed_offers_and_trusted_recipient
    offers = JSON.parse(@client.get("/offers", "HTTP_COOKIE" => @cookie).body).fetch("offers")
    assert_equal ["0x1_special_1m"], offers.map { |offer| offer.fetch("sku") }
    result = post
    assert_equal 201, result.status
    resource = JSON.parse(result.body).fetch("order")
    assert_equal "0x0sky", resource.dig("attributes", "recipient_subject")
    assert_equal 640, resource.dig("attributes", "amount_minor")
    assert_equal "nilx_visit", resource.dig("attributes", "link_provider")
    refute resource.fetch("attributes").key?("link_provider_user_id")
    assert_equal "pending", resource.dig("attributes", "status")
    issuer = @orders.find_for_issuer(resource.fetch("id"), issuer: "0x1")
    assert_equal "v" * 43, issuer.link_provider_user_id
  end

  def test_csrf_impersonation_and_cross_customer_access_fail_closed
    assert_equal 401, post("/orders", @purchase, "").status
    assert_equal 403, post("/orders", @purchase, @cookie, "HTTP_ORIGIN" => "https://evil.example").status
    assert_equal 403, post("/orders", @purchase, @cookie, "HTTP_X_MARKET_CSRF" => "").status
    assert_equal 422, post("/orders", @purchase.merge("recipient" => "0x0other")).status
    id = JSON.parse(post.body).dig("order", "id")
    assert_equal 404, @client.get("/orders/#{id}", "HTTP_COOKIE" => @other_cookie).status
    assert_equal 404, post("/orders/#{id}/cancel", {}, @other_cookie).status
  end

  def test_stale_quote_rejected_but_retry_after_price_change_keeps_original_order
    assert_equal 409, post("/orders", @purchase.merge("amount_minor" => 1)).status
    first = JSON.parse(post.body).fetch("order")
    @prices.apply_prices([{ "sku" => "0x1_special_1m", "amount_minor" => 800 }], denomination: "seeds")
    replay = post
    assert_equal 200, replay.status
    assert_equal first, JSON.parse(replay.body).fetch("order")
    assert_equal 409, post("/orders", @purchase.merge("idempotency_key" => "new-purchase-key")).status
  end

  def test_only_issuer_confirmation_fulfils_and_claim_prevents_cancellation
    id = JSON.parse(post.body).dig("order", "id")
    @orders.claim(id, issuer: "0x1")
    assert_equal 409, post("/orders/#{id}/cancel", {}).status
    assert_equal 404, post("/orders/#{id}/fulfil", {}).status
    @orders.fulfil(id, issuer: "0x1", reference: "identity:#{id}", amount_minor: 640,
      denomination: "seeds", recipient_subject: "0x0sky", term_months: 1)
    view = JSON.parse(@client.get("/orders/#{id}", "HTTP_COOKIE" => @cookie).body)
    assert_equal "fulfilled", view.dig("order", "attributes", "status")
    assert_equal "v" * 43, view.fetch("visit_id")
  end

  def test_cancel_and_expired_session_never_authorize_a_purchase
    id = JSON.parse(post.body).dig("order", "id")
    assert_equal "cancelled", JSON.parse(post("/orders/#{id}/cancel", {}).body).dig("order", "attributes", "status")
    assert_equal 200, post("/orders/#{id}/cancel", {}).status
    @now += 1800
    assert_equal 401, post.status
  end
  def test_order_freezes_the_calendar_term_and_its_authorization_deadline
    offer = JSON.parse(@client.get("/offers", "HTTP_COOKIE" => @cookie).body).fetch("offers").first
    assert_equal [1, "calendar_months_utc", 900],
                 offer.values_at("months", "term_policy", "authorization_ttl_seconds")
    attributes = JSON.parse(post.body).dig("order", "attributes")
    assert_equal({ "months" => 1, "policy" => "calendar_months_utc" }, attributes.fetch("term"))
    assert_equal (@now + 900).iso8601(6), attributes.fetch("authorization_expires_at")
  end

  def test_issuer_confirmation_must_name_the_frozen_term
    id = JSON.parse(post.body).dig("order", "id")
    @orders.claim(id, issuer: "0x1")
    [nil, 3].each do |months|
      error = assert_raises(M::Core::Conflict) do
        @orders.fulfil(id, issuer: "0x1", reference: "identity:#{id}", amount_minor: 640,
          denomination: "seeds", recipient_subject: "0x0sky", term_months: months)
      end
      assert_equal "issuer_confirmation_mismatch", error.code
    end
    assert_equal "processing", @orders.find_for_issuer(id, issuer: "0x1").status
  end

  def test_unclaimed_order_expires_into_a_rejection_never_a_debit
    id = JSON.parse(post.body).dig("order", "id")
    @now += 899
    assert_equal "pending", JSON.parse(@client.get("/orders/#{id}", "HTTP_COOKIE" => @cookie).body)
      .dig("order", "attributes", "status")
    @now += 1
    expired = @orders.claim(id, issuer: "0x1")
    assert_equal %w[rejected authorization_expired], [expired.status, expired.rejection_code]
    assert_nil expired.claimed_at
    assert_equal expired, @orders.claim(id, issuer: "0x1")
    assert_raises(M::Core::InvalidTransition) do
      @orders.fulfil(id, issuer: "0x1", reference: "identity:#{id}", amount_minor: 640,
        denomination: "seeds", recipient_subject: "0x0sky", term_months: 1)
    end
  end

  def test_claim_in_time_keeps_processing_after_the_deadline
    id = JSON.parse(post.body).dig("order", "id")
    @now += 899
    @orders.claim(id, issuer: "0x1")
    @now += 3600
    assert_equal "processing", @orders.claim(id, issuer: "0x1").status
    fulfilled = @orders.fulfil(id, issuer: "0x1", reference: "identity:#{id}", amount_minor: 640,
      denomination: "seeds", recipient_subject: "0x0sky", term_months: 1)
    assert_equal "fulfilled", fulfilled.status
  end

  def test_replay_cannot_change_quote_or_visit
    first = post
    assert_equal 201, first.status
    assert_equal 409, post("/orders", @purchase.merge("amount_minor" => 1)).status
    next_visit = login("a", "0x0sky", "x")
    assert_equal 409, post("/orders", @purchase, next_visit).status
    assert_equal 200, post.status
  end

end
