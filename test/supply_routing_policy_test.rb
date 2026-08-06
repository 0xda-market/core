# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/listings/listing"
require "zero_x_da/market/listings/supply_routing_policy"

class SupplyRoutingPolicyTest < Minitest::Test
  def setup
    @policy = ZeroXDA::Market::Listings::SupplyRoutingPolicy.new
    @now = Time.utc(2026, 8, 6, 12, 0, 0)
  end

  def test_assigns_price_ranked_shares_without_exposing_other_asks
    positions = @policy.positions([
      candidate("high", "9.5", 2),
      candidate("best", "8.5", 1),
      candidate("reserve", "9", 3)
    ])

    assert_equal %w[best reserve high], positions.map { |entry| entry.candidate.listing.id }
    assert_equal %w[best competitive unlikely], positions.map(&:status)
    assert_equal [
      BigDecimal("0.7"),
      BigDecimal("0.2"),
      BigDecimal("0.1")
    ], positions.map(&:estimated_share)
  end

  def test_selection_is_replay_stable_and_reaches_each_routing_tier
    candidates = [
      candidate("best", "8", 1),
      candidate("competitive", "9", 2),
      candidate("reserve", "9.5", 3)
    ]
    selected = 1_000.times.map do |index|
      @policy.select(candidates, seed: "quote-#{index}").listing.id
    end

    assert_equal selected, 1_000.times.map { |index| @policy.select(candidates, seed: "quote-#{index}").listing.id }
    assert_includes selected, "best"
    assert_includes selected, "competitive"
    assert_includes selected, "reserve"
    assert_operator selected.count("best"), :>, selected.count("competitive")
    assert_operator selected.count("competitive"), :>, selected.count("reserve")
  end

  private

  def candidate(id, cost, offset)
    listing = ZeroXDA::Market::Listings::Listing.new(
      id: id,
      seller_user_id: "seller-#{id}",
      sku: "premium_3m",
      quantity: "10",
      price_amount: cost,
      currency: "USDT",
      created_at: @now + offset
    )
    ZeroXDA::Market::Listings::SupplyRoutingPolicy::Candidate.new(
      listing: listing,
      cost_usdt: BigDecimal(cost)
    )
  end
end
