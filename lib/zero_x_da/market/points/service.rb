# frozen_string_literal: true
# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT

require_relative "point"

module ZeroXDA
  module Market
    module Points
      # Resolves Market's point addresses. An older link (an alias, or the
      # station's place) resolves to the same point and reports that it is not
      # canonical, so the browser can replace the visible URL.
      class Service
        Resolution = Data.define(:point, :canonical)

        def initialize(store:)
          @store = store
        end

        def all
          @store.all
        end

        # A decoded path segment, e.g. "zoloti", "zoloti-vorota" or "золоті".
        def resolve(segment)
          segment = segment.to_s
          return nil if segment.empty? || segment.length > 64 || !segment.valid_encoding?

          if (point = @store.find_address(segment))
            return Resolution.new(point: point, canonical: true)
          end

          point = @store.find_alias(segment)
          point ||= @store.find_address(segment.downcase) if segment.ascii_only?
          point && Resolution.new(point: point, canonical: false)
        end

        # The address of a station the 0x1 handoff names by its place, or of a
        # point it already names by address or alias.
        def address_for(owner_pub_dress:, point:)
          found = Points::SEGMENT.match?(point.to_s) && @store.find_place(owner_pub_dress: owner_pub_dress, place: point)
          found ||= resolve(point)&.point
          found&.address
        end
      end
    end
  end
end
