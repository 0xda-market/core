# frozen_string_literal: true

require "bigdecimal"
require "digest"

module ZeroXDA
  module Market
    module Listings
      # Routes profitable supply without exposing competitor asks. Price is the
      # primary rank signal; creation time and id only make equal asks stable.
      # A quote id provides an unpredictable, replay-stable allocation seed.
      class SupplyRoutingPolicy
        BASIS_POINTS = 10_000
        BEST_SHARE_BPS = 7_000
        COMPETITIVE_SHARE_BPS = 2_000

        Candidate = Struct.new(:listing, :cost_usdt, keyword_init: true)
        Position = Struct.new(
          :candidate,
          :rank,
          :status,
          :estimated_share,
          keyword_init: true
        )

        def positions(candidates)
          ranked = candidates.sort_by do |candidate|
            listing = candidate.listing
            [candidate.cost_usdt, listing.created_at, listing.id]
          end
          ranked.each_with_index.map do |candidate, rank|
            Position.new(
              candidate: candidate,
              rank: rank,
              status: status_for(rank),
              estimated_share: share_for(rank, ranked.length)
            ).freeze
          end.freeze
        end

        def select(candidates, seed:)
          ranked = positions(candidates)
          return nil if ranked.empty?
          return ranked.first.candidate if ranked.length == 1

          bucket = deterministic_bucket(seed, "primary")
          if ranked.length == 2
            return ranked[bucket < BEST_SHARE_BPS + reserve_share_bps(ranked.length) ? 0 : 1].candidate
          end

          return ranked[0].candidate if bucket < BEST_SHARE_BPS
          return ranked[1].candidate if bucket < BEST_SHARE_BPS + COMPETITIVE_SHARE_BPS

          reserve = ranked.drop(2)
          reserve.fetch(deterministic_bucket(seed, "reserve") % reserve.length).candidate
        end

        private

        def status_for(rank)
          return "best" if rank.zero?
          return "competitive" if rank == 1

          "unlikely"
        end

        def share_for(rank, count)
          basis_points = if count == 1
                           BASIS_POINTS
                         elsif count == 2
                           rank.zero? ? BEST_SHARE_BPS + reserve_share_bps(count) : COMPETITIVE_SHARE_BPS
                         elsif rank.zero?
                           BEST_SHARE_BPS
                         elsif rank == 1
                           COMPETITIVE_SHARE_BPS
                         else
                           reserve_share_bps(count) / (count - 2)
                         end
          BigDecimal(basis_points.to_s) / BASIS_POINTS
        end

        def reserve_share_bps(_count)
          BASIS_POINTS - BEST_SHARE_BPS - COMPETITIVE_SHARE_BPS
        end

        def deterministic_bucket(seed, namespace)
          digest = Digest::SHA256.hexdigest("#{namespace}:#{seed}")
          digest.to_i(16) % BASIS_POINTS
        end
      end
    end
  end
end
