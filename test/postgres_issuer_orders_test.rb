# frozen_string_literal: true

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
    @orders = ZeroXDA::Market::IssuerOrders::Service.new(store: @store, denominations: @denominations,
                                                         users: @identity_store)
  end

  def teardown
    @database&.disconnect
  end

  def test_full_lifecycle_persists_with_an_append_only_audit
    within_fixture do |customer|
      order, created = create_order(customer)
      assert created
      assert_equal [400, "0x1", "bond-#{customer.id}"], [order.amount_minor, order.issuer, order.recipient_subject]

      replay, replay_created = create_order(customer)
      refute replay_created
      assert_equal order.id, replay.id

      @orders.claim(order.id, issuer: "0x1")
      fulfilled = @orders.fulfil(order.id, issuer: "0x1", reference: "debit-#{order.id}", amount_minor: 400,
                                           denomination: "seeds", recipient_subject: order.recipient_subject)
      assert_equal fulfilled.to_h, @store.find(order.id).to_h
      assert_equal %w[pending processing fulfilled], @store.events(order.id).map(&:to_status)
      assert_equal({ "reference" => "debit-#{order.id}" }, @store.events(order.id).last.data)

      events = @connection[Sequel.qualify(:market, :issuer_order_events)].where(order_id: order.id)
      assert_raises(Sequel::DatabaseError) do
        @connection.transaction(savepoint: true) { events.update(actor: "customer") }
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

  def test_links_follow_the_issuers_binding_rules
    within_fixture do |customer|
      link = @store.find_link(issuer: "0x1", provider: "channel.example",
                              provider_user_id: @connection[Sequel.qualify(:market, :user_identities)]
                                .where(user_id: customer.id).get(:provider_user_id))
      renamed = @orders.link_account(issuer: "0x1", provider: link.provider, provider_user_id: link.provider_user_id,
                                     subject: link.subject, pub_dress: "renamed")
      assert_equal ["renamed", link.linked_at], [renamed.pub_dress, renamed.linked_at]

      error = assert_raises(Core::Conflict) do
        @connection.transaction(savepoint: true) do
          @orders.link_account(issuer: "0x1", provider: "channel.example", provider_user_id: SecureRandom.uuid,
                               subject: link.subject, pub_dress: "thief")
        end
      end
      assert_equal "issuer_account_link_conflict", error.code

      assert @orders.unlink_account(issuer: "0x1", provider: link.provider, provider_user_id: link.provider_user_id)
      assert_equal "issuer_account_unlinked", assert_raises(Core::Conflict) { create_order(customer) }.code
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
          "family" => "0x1_subscription", "payment_modes" => %w[USDT seeds],
          "purchase" => { "quantity_mode" => "single", "recipient" => { "provider" => "0x1", "modes" => ["self"] } }
        )
      )
      @denominations.apply_prices([{ "sku" => "issuer_order_fixture", "amount_minor" => 400 }], denomination: "seeds")
      identities = ZeroXDA::Market::Identity::Service.new(store: @identity_store)
      channel_user_id = SecureRandom.uuid
      user = identities.authenticate(provider: "channel.example", provider_user_id: channel_user_id).user
      @orders.link_account(issuer: "0x1", provider: "channel.example", provider_user_id: channel_user_id,
                           subject: "bond-#{user.id}", pub_dress: "fixture-#{user.id[0, 8]}")
      yield user
    end
  end

  def create_order(customer, key: "order-key-1")
    @orders.create(customer_user_id: customer.id, sku: "issuer_order_fixture", denomination: "seeds",
                   idempotency_key: key)
  end
end
