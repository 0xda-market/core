# frozen_string_literal: true
# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT

require_relative "test_helper"
require "securerandom"
require "zero_x_da/market/adapters/postgres_database"
require "zero_x_da/market/adapters/postgres_migrator"
require "zero_x_da/market/catalog/postgres_store"
require "zero_x_da/market/catalog/service"
require "zero_x_da/market/denominations/postgres_store"
require "zero_x_da/market/denominations/service"
require "zero_x_da/market/identity/postgres_store"
require "zero_x_da/market/identity/service"
require "zero_x_da/market/issuer_orders/memory_directory"
require "zero_x_da/market/issuer_orders/postgres_store"
require "zero_x_da/market/issuer_orders/service"

class PostgresIssuerOrdersTest < Minitest::Test
  Core = ZeroXDA::Market::Core

  def setup
    skip "TEST_DATABASE_URL is not configured" unless ENV["TEST_DATABASE_URL"]

    @database = ZeroXDA::Market::Adapters::PostgresDatabase.new(url: ENV.fetch("TEST_DATABASE_URL"), max_connections: 2)
    ZeroXDA::Market::Adapters::PostgresMigrator.new(
      database: @database, path: File.expand_path("../db/migrations", __dir__)
    ).migrate!
    @connection = @database.connection
    @store = ZeroXDA::Market::IssuerOrders::PostgresStore.new(database: @database)
    @identity_store = ZeroXDA::Market::Identity::PostgresStore.new(database: @database)
    catalog = ZeroXDA::Market::Catalog::Service.new(store: ZeroXDA::Market::Catalog::PostgresStore.new(database: @database))
    @denominations = ZeroXDA::Market::Denominations::Service.new(
      store: ZeroXDA::Market::Denominations::PostgresStore.new(database: @database), catalog: catalog
    )
    @directory = ZeroXDA::Market::IssuerOrders::MemoryDirectory.new({}, providers: %w[channel.example])
    @orders = ZeroXDA::Market::IssuerOrders::Service.new(store: @store, denominations: @denominations,
                                                         users: @identity_store, directory: @directory)
  end

  def teardown
    @database&.disconnect
  end

  def test_full_lifecycle_persists_with_an_append_only_audit
    within_fixture do |customer|
      order, created = create_order(customer)
      assert created
      assert_equal [400, "0x1", "fixture-#{customer.id[0, 8]}"], [order.amount_minor, order.issuer, order.recipient_subject]

      replay, replay_created = create_order(customer)
      refute replay_created
      assert_equal order.id, replay.id

      @orders.claim(order.id, issuer: "0x1")
      fulfilled = @orders.fulfil(order.id, issuer: "0x1", reference: "debit-#{order.id}", amount_minor: 400,
                                           denomination: "seeds", recipient_subject: order.recipient_subject,
                                           term_months: 1)
      assert_equal fulfilled.to_h, @store.find(order.id).to_h
      assert_equal %w[pending processing fulfilled], @store.events(order.id).map(&:to_status)
      assert_equal({ "reference" => "debit-#{order.id}" }, @store.events(order.id).last.data)

      events = @connection[Sequel.qualify(:market, :issuer_order_events)].where(order_id: order.id)
      assert_raises(Sequel::DatabaseError) do
        @connection.transaction(savepoint: true) { events.update(actor: "customer") }
      end
    end
  end

  def test_staged_special_640_seeds_order_is_auditable_but_not_live
    within_fixture do |customer|
      special = "0x1_special_1m"
      exclusive = "0x1_exclusive_1m"
      key = "special-seeds-quote-check"
      products = @connection[Sequel.qualify(:market, :products)]

      assert_equal "inactive", products.where(sku: special).get(:status)
      error = assert_raises(Core::Conflict) do
        @orders.create(customer_user_id: customer.id, sku: special, denomination: "seeds", idempotency_key: key)
      end
      assert_equal "denomination_price_unavailable", error.code

      # Activate only inside the rolled-back PostgreSQL test fixture.
      # This MUST NOT publish the catalog SKU or accept a real purchase.
      products.where(sku: special).update(status: "active")
      order, created = @orders.create(
        customer_user_id: customer.id, sku: special, denomination: "seeds", idempotency_key: key
      )
      assert created
      assert_equal [special, 640, "seeds", "0x1", "pending"],
                   [order.sku, order.amount_minor, order.denomination, order.issuer, order.status]
      assert_equal "fixture-#{customer.id[0, 8]}", order.recipient_subject

      @denominations.apply_prices([{ "sku" => special, "amount_minor" => 800 }], denomination: "seeds")
      replay, replay_created = @orders.create(
        customer_user_id: customer.id, sku: special, denomination: "seeds", idempotency_key: key
      )
      refute replay_created
      assert_equal [order.id, 640, order.price_id], [replay.id, replay.amount_minor, replay.price_id]

      claimed = @orders.claim(order.id, issuer: "0x1")
      assert_equal "processing", claimed.status
      assert_raises(Core::InvalidTransition) { @orders.cancel(order.id, customer_user_id: customer.id) }

      reference = "identity-debit-#{order.id}"
      confirm = lambda do
        @orders.fulfil(
          order.id, issuer: "0x1", reference: reference, amount_minor: order.amount_minor,
          denomination: "seeds", recipient_subject: order.recipient_subject, term_months: 1
        )
      end
      fulfilled = confirm.call
      assert_equal "fulfilled", fulfilled.status
      assert_equal fulfilled.to_h, confirm.call.to_h
      assert_equal %w[pending processing fulfilled], @store.events(order.id).map(&:to_status)
      assert_equal "issuer_reference_conflict",
                   assert_raises(Core::Conflict) {
                     @orders.fulfil(
                       order.id, issuer: "0x1", reference: "another-debit",
                       amount_minor: 640, denomination: "seeds", recipient_subject: order.recipient_subject,
                       term_months: 1
                     )
                   }.code

      # Even a temporarily active Exclusive has NO seeds denomination.
      products.where(sku: exclusive).update(status: "active")
      assert_equal "denomination_price_unavailable",
                   assert_raises(Core::Conflict) {
                     @orders.create(customer_user_id: customer.id, sku: exclusive,
                                    denomination: "seeds", idempotency_key: "exclusive-seeds-check")
                   }.code
    end
  end

  def test_term_and_authorization_deadline_persist_and_are_constrained
    within_fixture do |customer|
      order, = create_order(customer)
      assert_equal [1, "calendar_months_utc", nil],
                   [order.term_months, order.term_policy, order.authorization_expires_at]
      assert_equal order.to_h, @store.find(order.id).to_h

      link = ZeroXDA::Market::IssuerOrders::Service::Link.new(provider: "nilx_visit", provider_user_id: "v" * 43,
                                                              pub_dress: "fixture-visit")
      products = @connection[Sequel.qualify(:market, :products)]
      products.where(sku: "issuer_order_fixture").update(
        metadata: Sequel.pg_jsonb(products.where(sku: "issuer_order_fixture").get(:metadata).to_h
          .merge("supplier" => { "kind" => "system_broker", "id" => "0x1", "issuer" => "0x1" }))
      )
      visit_order, = @orders.create(customer_user_id: customer.id, sku: "issuer_order_fixture",
                                    denomination: "seeds", idempotency_key: "visit-order-1", verified_link: link)
      stored = @store.find(visit_order.id)
      assert_equal visit_order.to_h, stored.to_h
      assert_in_delta 900, stored.authorization_expires_at - stored.created_at, 0.001

      orders = @connection[Sequel.qualify(:market, :issuer_orders)].where(id: order.id)
      [{ term_policy: nil }, { term_months: 0 }, { term_policy: "thirty_days" },
       { authorization_expires_at: order.created_at }].each do |change|
        assert_raises(Sequel::CheckConstraintViolation, change.inspect) do
          @connection.transaction(savepoint: true) { orders.update(change) }
        end
      end
    end
  end

  def test_concurrent_create_with_one_key_keeps_one_order
    within_fixture do |customer|
      first, = create_order(customer)
      racing = ZeroXDA::Market::IssuerOrders::Order.new(**first.to_h, id: SecureRandom.uuid)
      event = ZeroXDA::Market::IssuerOrders::Event.new(order_id: racing.id, to_status: "pending", actor: "customer",
                                                       data: {}, created_at: racing.created_at)
      kept, created = @store.create(racing, event: event)
      refute created
      assert_equal first.id, kept.id
    end
  end

  def test_stale_writes_and_reused_references_fail_closed
    within_fixture do |customer|
      first, = create_order(customer)
      second, = create_order(customer, key: "order-key-2")
      claimed = @orders.claim(first.id, issuer: "0x1")
      event = ZeroXDA::Market::IssuerOrders::Event.new(order_id: first.id, from_status: "pending", to_status: "cancelled",
                                                       actor: "customer", data: {}, created_at: Time.now.utc)
      assert_raises(Core::ConcurrencyConflict) do
        @store.replace(first.cancel(at: Time.now.utc), expected_version: first.version, event: event)
      end
      assert_equal "processing", @store.find(first.id).status

      @orders.claim(second.id, issuer: "0x1")
      [claimed, @store.find(second.id)].each_with_index do |order, index|
        fulfilled = order.fulfil(reference: "debit-shared", at: Time.now.utc)
        done = ZeroXDA::Market::IssuerOrders::Event.new(order_id: order.id, from_status: "processing",
                                                        to_status: "fulfilled", actor: "issuer", data: {},
                                                        created_at: Time.now.utc)
        if index.zero?
          @store.replace(fulfilled, expected_version: order.version, event: done)
        else
          error = assert_raises(Core::Conflict) do
            @connection.transaction(savepoint: true) do
              @store.replace(fulfilled, expected_version: order.version, event: done)
            end
          end
          assert_equal "issuer_reference_conflict", error.code
        end
      end
    end
  end

  def test_queue_cursor_reaches_every_order_with_equal_timestamps
    within_fixture do |customer|
      clock_time = Time.utc(2026, 10, 22, 12, 0, 0)
      orders = ZeroXDA::Market::IssuerOrders::Service.new(store: @store, denominations: @denominations,
                                                          users: @identity_store, directory: @directory,
                                                          clock: -> { clock_time })
      ids = 5.times.map do |index|
        orders.create(customer_user_id: customer.id, sku: "issuer_order_fixture", denomination: "seeds",
                      idempotency_key: "same-time-#{index}").first.id
      end

      seen = []
      cursor = nil
      loop do
        page, cursor = orders.queue(issuer: "0x1", limit: 2, cursor: cursor)
        seen.concat(page.map(&:id))
        break unless cursor
      end
      assert_equal ids.sort, (seen & ids).sort
      assert_equal seen.uniq, seen
    end
  end

  def test_unknown_or_malformed_ids_are_not_found
    assert_nil @store.find("not-a-uuid")
    assert_nil @store.find(SecureRandom.uuid)
    assert_empty @store.events("not-a-uuid")
  end

  private

  # An active, eligible 0x1 good and a customer with a 0x1 account, all
  # rolled back so the staged catalog is never changed.
  def within_fixture
    @connection.transaction(rollback: :always) do
      products = @connection[Sequel.qualify(:market, :products)]
      products.insert(
        sku: "issuer_order_fixture", short_name: "fixture", name: "fixture", button_label: "fixture",
        status: "active", position: products.max(:position).to_i + 1,
        metadata: Sequel.pg_jsonb(
          "family" => "0x1_subscription", "duration_months" => 1, "payment_modes" => %w[USDT seeds],
          "purchase" => { "quantity_mode" => "single", "recipient" => { "provider" => "0x1", "modes" => ["self"] } }
        )
      )
      @denominations.apply_prices([{ "sku" => "issuer_order_fixture", "amount_minor" => 400 }], denomination: "seeds")
      identities = ZeroXDA::Market::Identity::Service.new(store: @identity_store)
      channel_user_id = SecureRandom.uuid
      user = identities.authenticate(provider: "channel.example", provider_user_id: channel_user_id).user
      @directory.bind("channel.example", channel_user_id, "fixture-#{user.id[0, 8]}")
      yield user
    end
  end

  def create_order(customer, key: "order-key-1")
    @orders.create(customer_user_id: customer.id, sku: "issuer_order_fixture", denomination: "seeds",
                   idempotency_key: key)
  end
end
