# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "rack/mock"
require "zero_x_da/market/catalog/memory_store"
require "zero_x_da/market/catalog/product"
require "zero_x_da/market/catalog/service"
require "zero_x_da/market/denominations/memory_store"
require "zero_x_da/market/denominations/service"
require "zero_x_da/market/identity/memory_store"
require "zero_x_da/market/identity/service"
require "zero_x_da/market/issuer_orders/memory_store"
require "zero_x_da/market/issuer_orders/service"
require "zero_x_da/market/transport/issuer_api"
require "zero_x_da/market/transport/json_api"

class IssuerOrdersTest < Minitest::Test
  include KernelFixture

  ISSUER = "issuer.example"
  Core = ZeroXDA::Market::Core

  def setup
    @clock = MutableClock.new
    @catalog = ZeroXDA::Market::Catalog::Service.new(
      store: ZeroXDA::Market::Catalog::MemoryStore.new(
        products: [
          product("game_special", position: 1),
          product("game_other_issuer", position: 2, recipient_provider: "elsewhere.example"),
          product("game_staged", position: 3, status: "inactive")
        ]
      ),
      clock: @clock
    )
    @denominations = ZeroXDA::Market::Denominations::Service.new(
      store: ZeroXDA::Market::Denominations::MemoryStore.new(
        denominations: [
          ZeroXDA::Market::Denominations::Denomination.new(
            code: "seeds", symbol: "₴€£", scale: 0, issuer: ISSUER,
            product_families: %w[game_subscription], created_at: @clock.call
          )
        ]
      ),
      catalog: @catalog, clock: @clock
    )
    @denominations.apply_prices(
      [{ "sku" => "game_special", "amount_minor" => 400 }, { "sku" => "game_other_issuer", "amount_minor" => 10 },
       { "sku" => "game_staged", "amount_minor" => 900 }],
      denomination: "seeds"
    )

    @identity_store = ZeroXDA::Market::Identity::MemoryStore.new
    identities = ZeroXDA::Market::Identity::Service.new(store: @identity_store, clock: @clock, id_generator: SequenceIDs.new)
    @customer = identities.authenticate(provider: "channel.example", provider_user_id: "100").user
    @stranger = identities.authenticate(provider: "channel.example", provider_user_id: "200").user

    @store = ZeroXDA::Market::IssuerOrders::MemoryStore.new
    @orders = ZeroXDA::Market::IssuerOrders::Service.new(
      store: @store, denominations: @denominations, users: @identity_store, clock: @clock,
      id_generator: SequenceIDs.new
    )
    @orders.link_account(issuer: ISSUER, provider: "channel.example", provider_user_id: "100",
                         subject: "bond-1", pub_dress: "zero")
    kernel, = build_kernel(provider: TestProvider.new(clock: @clock), clock: @clock)
    @client = Rack::MockRequest.new(
      ZeroXDA::Market::Transport::JSONAPI.new(kernel: kernel, catalog: @catalog, issuer_orders: @orders)
    )
    @issuer = Rack::MockRequest.new(
      ZeroXDA::Market::Transport::IssuerAPI.new(issuer_orders: @orders, issuer: ISSUER, token: "issuer-secret")
    )
  end

  def test_order_snapshots_price_and_the_customers_own_issuer_account
    order, created = create_order
    assert created
    assert_equal ["pending", 400, "seeds", ISSUER, "bond-1"],
                 [order.status, order.amount_minor, order.denomination, order.issuer, order.recipient_subject]

    @clock.advance(60)
    @denominations.apply_prices([{ "sku" => "game_special", "amount_minor" => 380 }], denomination: "seeds")
    replay, replay_created = create_order
    refute replay_created
    assert_equal [order.id, 400], [replay.id, replay.amount_minor]
    assert_equal 1, @orders.events(order.id).length
  end

  def test_order_records_which_channel_account_selected_the_recipient
    order, = create_order
    assert_equal ["channel.example", "100", "bond-1"],
                 [order.link_provider, order.link_provider_user_id, order.recipient_subject]
  end

  def test_account_status_shows_only_the_public_handle_or_unlinked
    assert_equal({ linked: true, issuer: ISSUER, pub_dress: "zero", provider: "channel.example" },
                 @orders.account_status(customer_user_id: @customer.id, issuer: ISSUER))
    assert_equal({ linked: false, issuer: ISSUER }, @orders.account_status(customer_user_id: @stranger.id, issuer: ISSUER))
  end

  def test_relinking_updates_the_handle_and_unlinking_stops_new_orders
    first = @store.find_link(issuer: ISSUER, provider: "channel.example", provider_user_id: "100")
    @clock.advance(60)
    renamed = @orders.link_account(issuer: ISSUER, provider: "channel.example", provider_user_id: "100",
                                   subject: "bond-1", pub_dress: "zero-renamed")
    assert_equal ["zero-renamed", first.linked_at, @clock.call], [renamed.pub_dress, renamed.linked_at, renamed.updated_at]

    assert @orders.unlink_account(issuer: ISSUER, provider: "channel.example", provider_user_id: "100")
    refute @orders.unlink_account(issuer: ISSUER, provider: "channel.example", provider_user_id: "100")
    assert_equal "issuer_account_unlinked", assert_raises(Core::Conflict) { create_order }.code
  end

  def test_one_issuer_account_holds_one_channel_account_per_provider
    error = assert_raises(Core::Conflict) do
      @orders.link_account(issuer: ISSUER, provider: "channel.example", provider_user_id: "200",
                           subject: "bond-1", pub_dress: "zero")
    end
    assert_equal "issuer_account_link_conflict", error.code
    assert_nil @store.find_link(issuer: ISSUER, provider: "channel.example", provider_user_id: "200")
  end

  def test_channel_accounts_linked_to_different_issuer_accounts_are_ambiguous
    @identity_store.insert_identity(
      ZeroXDA::Market::Identity::ExternalIdentity.new(id: "identity-other", user_id: @customer.id,
                                                      provider: "other.example", provider_user_id: "100",
                                                      created_at: @clock.call)
    )
    @orders.link_account(issuer: ISSUER, provider: "other.example", provider_user_id: "100",
                         subject: "bond-2", pub_dress: "other")

    assert_equal "recipient_ambiguous", assert_raises(Core::Conflict) { create_order }.code
    assert_equal "recipient_ambiguous",
                 assert_raises(Core::Conflict) { @orders.account_status(customer_user_id: @customer.id, issuer: ISSUER) }.code
  end

  def test_reused_idempotency_key_for_another_order_conflicts
    create_order
    error = assert_raises(Core::Conflict) { create_order(sku: "game_other_issuer") }
    assert_equal "idempotency_conflict", error.code
  end

  def test_only_purchasable_goods_with_an_issuer_account_can_be_ordered
    assert_equal "denomination_price_unavailable",
                 assert_raises(Core::Conflict) { create_order(sku: "game_staged") }.code
    assert_equal "recipient_mode_unsupported",
                 assert_raises(Core::Conflict) { create_order(sku: "game_other_issuer", key: "order-key-2") }.code
    assert_equal "issuer_account_unlinked",
                 assert_raises(Core::Conflict) { create_order(customer: @stranger) }.code
    assert_raises(Core::NotFound) { create_order(denomination: "gems") }
    assert_raises(ArgumentError) { create_order(key: "short") }
  end

  def test_issuer_claims_then_fulfils_with_an_exact_confirmation
    order, = create_order
    @orders.claim(order.id, issuer: ISSUER)
    assert_equal "processing", @orders.claim(order.id, issuer: ISSUER).status

    mismatch = assert_raises(Core::Conflict) { fulfil(order, amount_minor: 399, recipient_subject: "bond-2") }
    assert_equal "issuer_confirmation_mismatch", mismatch.code
    assert_equal %w[amount_minor recipient_subject], mismatch.details["fields"]
    assert_equal "processing", @orders.find_for_issuer(order.id, issuer: ISSUER).status

    fulfilled = fulfil(order)
    assert_equal ["fulfilled", "debit-1"], [fulfilled.status, fulfilled.issuer_reference]
    assert_equal fulfilled, fulfil(order)
    assert_equal "issuer_reference_conflict",
                 assert_raises(Core::Conflict) { fulfil(order, reference: "debit-2") }.code
    assert_equal [[nil, "pending", "customer"], %w[pending processing issuer], %w[processing fulfilled issuer]],
                 @orders.events(order.id).map { |event| [event.from_status, event.to_status, event.actor] }
  end

  def test_fulfil_replay_requires_the_same_complete_confirmation
    order, = create_order
    @orders.claim(order.id, issuer: ISSUER)
    fulfilled = fulfil(order)

    [
      -> { fulfil(order, amount_minor: 1) },
      -> { fulfil(order, recipient_subject: "bond-2") },
      lambda do
        @orders.fulfil(order.id, issuer: ISSUER, reference: "debit-1", amount_minor: order.amount_minor,
                                 denomination: "gems", recipient_subject: order.recipient_subject)
      end
    ].each do |conflicting|
      assert_equal "issuer_confirmation_mismatch", assert_raises(Core::Conflict) { conflicting.call }.code
    end
    assert_equal fulfilled, fulfil(order)
    assert_equal 3, @orders.events(order.id).length
  end

  def test_unclaimed_order_cannot_be_fulfilled_and_references_are_unique
    first, = create_order
    second, = create_order(key: "order-key-2")
    assert_raises(Core::InvalidTransition) { fulfil(first) }

    [first, second].each { |order| @orders.claim(order.id, issuer: ISSUER) }
    fulfil(first)
    assert_equal "issuer_reference_conflict", assert_raises(Core::Conflict) { fulfil(second) }.code
  end

  def test_cancel_is_only_possible_before_the_issuer_claims
    pending, = create_order
    assert_equal "cancelled", @orders.cancel(pending.id, customer_user_id: @customer.id).status
    assert_equal "cancelled", @orders.cancel(pending.id, customer_user_id: @customer.id).status
    assert_raises(Core::InvalidTransition) { @orders.claim(pending.id, issuer: ISSUER) }

    claimed, = create_order(key: "order-key-2")
    @orders.claim(claimed.id, issuer: ISSUER)
    assert_raises(Core::InvalidTransition) { @orders.cancel(claimed.id, customer_user_id: @customer.id) }
  end

  def test_issuer_rejection_is_idempotent_and_terminal
    order, = create_order
    rejected = @orders.reject(order.id, issuer: ISSUER, code: "insufficient_balance")
    assert_equal ["rejected", "insufficient_balance"], [rejected.status, rejected.rejection_code]
    assert_equal rejected, @orders.reject(order.id, issuer: ISSUER, code: "insufficient_balance")
    assert_raises(Core::InvalidTransition) { @orders.reject(order.id, issuer: ISSUER, code: "other_reason") }
    assert_raises(ArgumentError) do
      @orders.reject(create_order(key: "order-key-2").first.id, issuer: ISSUER, code: "Bad Code")
    end
  end

  def test_orders_are_scoped_to_their_customer_and_issuer
    order, = create_order
    assert_raises(Core::NotFound) { @orders.find_for_customer(order.id, customer_user_id: @stranger.id) }
    assert_raises(Core::NotFound) { @orders.cancel(order.id, customer_user_id: @stranger.id) }
    assert_raises(Core::NotFound) { @orders.claim(order.id, issuer: "elsewhere.example") }
    assert_empty @orders.queue(issuer: "elsewhere.example")
    assert_equal [order.id], @orders.queue(issuer: ISSUER).map(&:id)
  end

  def test_client_api_creates_replays_reads_and_cancels
    created = post(@client, "/v1/issuer-orders", order_body)
    assert_equal 201, created.status, created.body
    id = JSON.parse(created.body).dig("data", "id")
    assert_equal 200, post(@client, "/v1/issuer-orders", order_body).status

    read = @client.get("/v1/issuer-orders/#{id}?actor_user_id=#{@customer.id}")
    assert_equal ["pending", 400], JSON.parse(read.body).dig("data", "attributes").values_at("status", "amount_minor")
    assert_equal 404, @client.get("/v1/issuer-orders/#{id}?actor_user_id=#{@stranger.id}").status

    refute JSON.parse(read.body).dig("data", "attributes").key?("recipient_subject")

    status = JSON.parse(@client.get("/v1/issuer-accounts/#{ISSUER}?actor_user_id=#{@customer.id}").body)
    assert_equal({ "linked" => true, "pub_dress" => "zero", "provider" => "channel.example" },
                 status.dig("data", "attributes"))
    unlinked = JSON.parse(@client.get("/v1/issuer-accounts/#{ISSUER}?actor_user_id=#{@stranger.id}").body)
    assert_equal({ "linked" => false }, unlinked.dig("data", "attributes"))

    cancelled = post(@client, "/v1/issuer-orders/#{id}/cancel", { actor_user_id: @customer.id })
    assert_equal "cancelled", JSON.parse(cancelled.body).dig("data", "attributes", "status")
    assert_equal 409, post(@client, "/v1/issuer-orders", order_body(sku: "game_other_issuer")).status
  end

  def test_issuer_api_requires_its_token_and_drives_the_order
    created = post(@client, "/v1/issuer-orders", order_body)
    id = JSON.parse(created.body).dig("data", "id")

    assert_equal 401, @issuer.get("/v1/orders").status
    queue = JSON.parse(@issuer.get("/v1/orders", auth).body)
    assert_equal [id], queue.fetch("data").map { |order| order.fetch("id") }

    assert_equal 200, post(@issuer, "/v1/orders/#{id}/claim", nil, auth).status
    mismatch = post(@issuer, "/v1/orders/#{id}/fulfil", confirmation(amount_minor: 1), auth)
    assert_equal 409, mismatch.status
    assert_equal "issuer_confirmation_mismatch", JSON.parse(mismatch.body).dig("errors", 0, "code")

    fulfilled = post(@issuer, "/v1/orders/#{id}/fulfil", confirmation, auth)
    assert_equal 200, fulfilled.status, fulfilled.body
    assert_equal "fulfilled", JSON.parse(fulfilled.body).dig("data", "attributes", "status")
    assert_equal 404, @issuer.get("/v1/orders/#{id}/unknown", auth).status

    linked = @issuer.put("/v1/account-links", auth.merge("CONTENT_TYPE" => "application/json",
                                                         input: JSON.generate(provider: "channel.example",
                                                                              provider_user_id: "200",
                                                                              subject: "bond-2", pub_dress: "two")))
    assert_equal 200, linked.status, linked.body
    assert_equal "two", JSON.parse(linked.body).dig("data", "attributes", "pub_dress")
    removed = @issuer.delete("/v1/account-links?provider=channel.example&provider_user_id=200", auth)
    assert JSON.parse(removed.body).dig("meta", "removed")
    assert_equal 401, @issuer.delete("/v1/account-links?provider=channel.example&provider_user_id=100").status
    assert_equal 400, post(@issuer, "/v1/orders/#{id}/reject", {}, auth).status
  end

  private

  def product(sku, position:, status: "active", recipient_provider: ISSUER)
    ZeroXDA::Market::Catalog::Product.new(
      sku: sku, name: sku, button_label: sku, position: position, status: status, created_at: @clock.call,
      metadata: {
        "family" => "game_subscription", "payment_modes" => %w[USDT seeds],
        "purchase" => { "quantity_mode" => "single", "recipient" => { "provider" => recipient_provider, "modes" => ["self"] } }
      }
    )
  end

  def create_order(customer: @customer, sku: "game_special", denomination: "seeds", key: "order-key-1")
    @orders.create(customer_user_id: customer.id, sku: sku, denomination: denomination, idempotency_key: key)
  end

  def fulfil(order, reference: "debit-1", amount_minor: order.amount_minor, recipient_subject: order.recipient_subject)
    @orders.fulfil(order.id, issuer: ISSUER, reference: reference, amount_minor: amount_minor,
                             denomination: order.denomination, recipient_subject: recipient_subject)
  end

  def order_body(sku: "game_special")
    { actor_user_id: @customer.id, sku: sku, denomination: "seeds", idempotency_key: "order-key-1" }
  end

  def confirmation(amount_minor: 400)
    { issuer_reference: "debit-1", amount_minor: amount_minor, denomination: "seeds", recipient_subject: "bond-1" }
  end

  def auth
    { "HTTP_AUTHORIZATION" => "Bearer issuer-secret" }
  end

  def post(client, path, document, headers = {})
    options = headers.merge("CONTENT_TYPE" => "application/json")
    options[:input] = JSON.generate(document) if document
    client.post(path, options)
  end
end
