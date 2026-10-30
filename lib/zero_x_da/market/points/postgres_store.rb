# frozen_string_literal: true
# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT

require "sequel"
require_relative "point"

module ZeroXDA
  module Market
    module Points
      class PostgresStore
        def initialize(database:)
          @database = database.connection
          @points = @database[Sequel.qualify(:market, :point_addresses)]
          @aliases = @database[Sequel.qualify(:market, :point_address_aliases)]
        end

        def all
          @points.order(:address).all.map { |row| deserialize(row) }
        end

        def find_address(address)
          row = @points.where(address: address.to_s).first
          row && deserialize(row)
        end

        def find_alias(name)
          address = @aliases.where(alias: name.to_s).get(:address)
          address && find_address(address)
        end

        def find_place(owner_pub_dress:, place:)
          row = @points.where(owner_pub_dress: owner_pub_dress.to_s, place: place.to_s).first
          row && deserialize(row)
        end

        private

        def deserialize(row)
          Point.new(address: row.fetch(:address), owner_pub_dress: row.fetch(:owner_pub_dress), place: row.fetch(:place))
        end
      end
    end
  end
end
