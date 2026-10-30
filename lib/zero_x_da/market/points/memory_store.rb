# frozen_string_literal: true
# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT

require_relative "point"

module ZeroXDA
  module Market
    module Points
      class MemoryStore
        def initialize(points: [], aliases: {})
          @points = points.to_h { |point| [point.address, point] }.freeze
          @aliases = aliases.transform_keys(&:to_s).freeze
          @aliases.each_value { |address| raise ArgumentError, "alias names an unknown address" unless @points.key?(address) }
        end

        def all
          @points.values.sort_by(&:address)
        end

        def find_address(address)
          @points[address]
        end

        def find_alias(name)
          address = @aliases[name]
          address && @points[address]
        end

        def find_place(owner_pub_dress:, place:)
          @points.values.find { |point| point.owner_pub_dress == owner_pub_dress && point.place == place }
        end
      end
    end
  end
end
