# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/listings/listing"
require "zero_x_da/market/listings/supply_routing_policy"

class SupplyRoutingPolicyTest < Minitest::Test
  def setup
    @policy = ZeroXDA::Market::Listings::SupplyRoutingPolicy.new
    @now = Time.utc(2026, 8, 6, 12, 0, 0)
  end

  def test_one_candidate_receives_all_traffic
    position = @policy.positions([candidate("only", "10", 1)]).fetch(0)

    assert_equal "best", position.status
    assert_equal BigDecimal("1"), position.estimated_share
    assert_equal "only", @policy.select([candidate("only", "10", 1)], seed: "quote-1").listing.id
  end

  def test_assigns_price_sensitive_shares_with_a_fixed_reserve_pool
    positions = @policy.positions([
      candidate("high", "9.5", 2),
      candidate("best", "8.5", 1),
      candidate("competitive", "9", 3)
    ])

    assert_equal %w[best competitive high], positions.map { |entry| entry.candidate.listing.id }
    assert_equal %w[best competitive unlikely], positions.map(&:status)
    assert_equal [
      BigDecimal("0.8028"),
      BigDecimal("0.1639"),
      BigDecimal("0.0333")
    ], positions.map(&:estimated_share)
    assert_equal BigDecimal("1"), positions.sum(&:estimated_share)
  end

  def test_equal_asks_split_traffic_equally_instead_of_using_rank_as_an_advantage
    positions = @policy.positions([
      candidate("older", "10", 1),
      candidate("newer", "10", 2)
    ])

    assert_equal [BigDecimal("0.5"), BigDecimal("0.5")], positions.map(&:estimated_share)
  end

  def test_lowering_an_ask_improves_share_continuously_before_becoming_best
    farther = @policy.positions([
      candidate("best", "10", 1),
      candidate("broker", "10.5", 2)
    ]).find { |entry| entry.candidate.listing.id == "broker" }
    closer = @policy.positions([
      candidate("best", "10", 1),
      candidate("broker", "10.2", 2)
    ]).find { |entry| entry.candidate.listing.id == "broker" }
    almost_equal = @policy.positions([
      candidate("best", "10", 1),
      candidate("broker", "10.1", 2)
    ]).find { |entry| entry.candidate.listing.id == "broker" }

    assert_equal BigDecimal("0.23"), farther.estimated_share
    assert_equal BigDecimal("0.4012"), closer.estimated_share
    assert_equal BigDecimal("0.4528"), almost_equal.estimated_share
    assert_operator closer.estimated_share, :>, farther.estimated_share
    assert_operator almost_equal.estimated_share, :>, closer.estimated_share
  end

  def test_offer_at_or_beyond_competitive_spread_keeps_only_reserve_traffic
    positions = @policy.positions([
      candidate("best", "10", 1),
      candidate("reserve", "11", 2)
    ])

    assert_equal %w[best unlikely], positions.map(&:status)
    assert_equal [BigDecimal("0.95"), BigDecimal("0.05")], positions.map(&:estimated_share)
  end

  def test_selection_is_replay_stable_and_reaches_price_weighted_candidates
    candidates = [
      candidate("best", "8", 1),
      candidate("competitive", "8.4", 2),
      candidate("reserve", "8.8", 3)
    ]
    selected = 2_000.times.map do |index|
      @policy.select(candidates, seed: "quote-#{index}").listing.id
    end

    assert_equal selected, 2_000.times.map { |index| @policy.select(candidates, seed: "quote-#{index}").listing.id }
    assert_includes selected, "best"
    assert_includes selected, "competitive"
    assert_includes selected, "reserve"
    assert_operator selected.count("best"), :>, selected.count("competitive")
    assert_operator selected.count("competitive"), :>, selected.count("reserve")
  end

  def test_rejects_invalid_policy_parameters_and_candidate_costs
    policy_class = ZeroXDA::Market::Listings::SupplyRoutingPolicy

    assert_raises(ArgumentError) { policy_class.new(reserve_pool_bps: 10_000) }
    assert_raises(ArgumentError) { policy_class.new(competitive_spread_bps: 0) }
    assert_raises(ArgumentError) { @policy.positions([candidate("zero", "0", 1)]) }
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
