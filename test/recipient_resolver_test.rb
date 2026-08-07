# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/catalog/product"
require "zero_x_da/market/identity/memory_store"
require "zero_x_da/market/identity/service"
require "zero_x_da/market/marketplace/recipient_resolver"

class RecipientResolverTest < Minitest::Test
  def setup
    @clock = MutableClock.new
    @store = ZeroXDA::Market::Identity::MemoryStore.new
    identity = ZeroXDA::Market::Identity::Service.new(
      store: @store,
      clock: @clock,
      id_generator: SequenceIDs.new
    )
    @client = identity.authenticate(
      provider: "telegram",
      provider_user_id: "79",
      provider_data: { username: "sasha", is_premium: false }
    ).user
    @premium_user = identity.authenticate(
      provider: "telegram",
      provider_user_id: "80",
      provider_data: { username: "premium_user", is_premium: true }
    ).user
    @resolver = ZeroXDA::Market::Marketplace::RecipientResolver.new(identities: @store)
  end

  def test_resolves_self_from_the_authenticated_external_identity
    recipient = @resolver.resolve(
      product: premium_product,
      actor_user_id: @client.id,
      recipient: { mode: "self" }
    )

    assert_equal "self", recipient.mode
    assert_equal "telegram", recipient.provider
    assert_equal "sasha", recipient.username
    assert_equal "verified", recipient.eligibility.fetch("status")
  end

  def test_rejects_known_recipient_with_active_premium
    error = assert_raises(ZeroXDA::Market::Core::Conflict) do
      @resolver.resolve(
        product: premium_product,
        actor_user_id: @client.id,
        recipient: { mode: "username", username: "@premium_user" }
      )
    end

    assert_equal "premium_already_active", error.code
  end

  def test_allows_unknown_username_without_claiming_verified_eligibility
    recipient = @resolver.resolve(
      product: premium_product,
      actor_user_id: @client.id,
      recipient: { mode: "username", username: "new_user" }
    )

    assert_equal "new_user", recipient.username
    assert_equal "unknown", recipient.eligibility.fetch("status")
  end

  def test_stars_do_not_apply_the_premium_eligibility_rule
    recipient = @resolver.resolve(
      product: stars_product,
      actor_user_id: @client.id,
      recipient: { mode: "username", username: "premium_user" }
    )

    assert_equal "not_required", recipient.eligibility.fetch("status")
  end

  private

  def premium_product
    product(
      "premium_3m",
      family: "telegram_premium",
      duration_months: 3,
      purchase: {
        quantity_mode: "single",
        recipient: {
          provider: "telegram",
          modes: %w[self username],
          eligibility: { is_premium: false },
          ineligible_code: "premium_already_active"
        }
      }
    )
  end

  def stars_product
    product(
      "stars_500",
      family: "telegram_stars",
      amount: 500,
      purchase: {
        quantity_mode: "single",
        recipient: { provider: "telegram", modes: %w[self username] }
      }
    )
  end

  def product(sku, metadata)
    ZeroXDA::Market::Catalog::Product.new(
      sku: sku,
      short_name: sku,
      name: sku,
      button_label: sku,
      metadata: metadata,
      position: 1,
      created_at: @clock.call
    )
  end
end
