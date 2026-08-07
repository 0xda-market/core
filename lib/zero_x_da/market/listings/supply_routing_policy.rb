# frozen_string_literal: true

require "bigdecimal"
require "digest"

module ZeroXDA
  module Market
    module Listings
      # Routes profitable supply without exposing competitor asks. Price is the
      # primary allocation signal; creation time and id only make equal asks
      # stable. A quote id provides an unpredictable, replay-stable seed.
      class SupplyRoutingPolicy
        BASIS_POINTS = 10_000
        DEFAULT_RESERVE_POOL_BPS = 1_000
        DEFAULT_COMPETITIVE_SPREAD_BPS = 1_000

        Candidate = Struct.new(:listing, :cost_usdt, keyword_init: true)
        Position = Struct.new(
          :candidate,
          :rank,
          :status,
          :estimated_share,
          keyword_init: true
        )

        def initialize(
          reserve_pool_bps: DEFAULT_RESERVE_POOL_BPS,
          competitive_spread_bps: DEFAULT_COMPETITIVE_SPREAD_BPS
        )
          @reserve_pool_bps = basis_points(
            reserve_pool_bps,
            field: "reserve_pool_bps",
            minimum: 0,
            maximum: BASIS_POINTS - 1
          )
          @competitive_spread_bps = basis_points(
            competitive_spread_bps,
            field: "competitive_spread_bps",
            minimum: 1,
            maximum: BASIS_POINTS
          )
        end

        def positions(candidates)
          ranked, allocations, scores = routing_plan(candidates)
          ranked.each_with_index.map do |candidate, rank|
            Position.new(
              candidate: candidate,
              rank: rank,
              status: status_for(scores.fetch(rank)),
              estimated_share: BigDecimal(allocations.fetch(rank).to_s) / BASIS_POINTS
            ).freeze
          end.freeze
        end

        def select(candidates, seed:)
          ranked, allocations, = routing_plan(candidates)
          return nil if ranked.empty?
          return ranked.first if ranked.length == 1

          bucket = deterministic_bucket(seed, "allocation")
          cumulative = 0
          ranked.each_with_index do |candidate, index|
            cumulative += allocations.fetch(index)
            return candidate if bucket < cumulative
          end

          ranked.last
        end

        private

        def routing_plan(candidates)
          ranked = candidates.sort_by do |candidate|
            listing = candidate.listing
            [candidate_cost(candidate), listing.created_at, listing.id]
          end
          return [ranked.freeze, [].freeze, [].freeze] if ranked.empty?
          if ranked.length == 1
            return [ranked.freeze, [BASIS_POINTS].freeze, [maximum_score].freeze]
          end

          best_cost = candidate_cost(ranked.first)
          scores = ranked.map do |candidate|
            competitive_score(candidate_cost(candidate), best_cost)
          end
          reserve = reserve_allocations(ranked.length)
          performance = proportional_allocations(
            scores,
            total_bps: BASIS_POINTS - @reserve_pool_bps
          )
          allocations = reserve.each_index.map do |index|
            reserve.fetch(index) + performance.fetch(index)
          end

          [ranked.freeze, allocations.freeze, scores.freeze]
        end

        def competitive_score(cost, best_cost)
          gap_bps = relative_gap_bps(cost, best_cost)
          return 0 if gap_bps >= @competitive_spread_bps

          remaining = @competitive_spread_bps - gap_bps
          remaining * remaining
        end

        def maximum_score
          @competitive_spread_bps * @competitive_spread_bps
        end

        def relative_gap_bps(cost, best_cost)
          ((((cost / best_cost) - 1) * BASIS_POINTS).floor).clamp(0, BASIS_POINTS)
        end

        def reserve_allocations(count)
          base = @reserve_pool_bps / count
          remainder = @reserve_pool_bps % count
          Array.new(count) do |index|
            base + (index < remainder ? 1 : 0)
          end
        end

        def proportional_allocations(scores, total_bps:)
          score_total = scores.sum
          base = scores.map { |score| (total_bps * score) / score_total }
          remainders = scores.each_index.map do |index|
            [(total_bps * scores.fetch(index)) % score_total, index]
          end
          remaining = total_bps - base.sum
          remainders.sort_by { |remainder, index| [-remainder, index] }
                    .first(remaining)
                    .each { |_, index| base[index] += 1 }
          base
        end

        def status_for(score)
          return "best" if score == maximum_score
          return "competitive" if score.positive?

          "unlikely"
        end

        def candidate_cost(candidate)
          cost = BigDecimal(candidate.cost_usdt.to_s)
          raise ArgumentError, "routing candidate cost must be positive" unless cost.positive?

          cost
        end

        def basis_points(value, field:, minimum:, maximum:)
          unless value.is_a?(Integer) && value.between?(minimum, maximum)
            raise ArgumentError, "#{field} must be an integer between #{minimum} and #{maximum}"
          end

          value
        end

        def deterministic_bucket(seed, namespace)
          digest = Digest::SHA256.hexdigest("#{namespace}:#{seed}")
          digest.to_i(16) % BASIS_POINTS
        end
      end
    end
  end
end
