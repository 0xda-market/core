# frozen_string_literal: true
# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT

module ZeroXDA
  module Market
    module Points
      SEGMENT = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

      # A Market point's public address: https://0xda-market.nilx.one/{address}.
      # The address is a location, not a display name; the 0x1 station it
      # names is `{owner_pub_dress}-{place}`.
      Point = Data.define(:address, :owner_pub_dress, :place) do
        def initialize(address:, owner_pub_dress:, place:)
          { address: address, owner_pub_dress: owner_pub_dress, place: place }.each do |field, value|
            raise ArgumentError, "#{field} is invalid" unless value.is_a?(String) && value.length <= 64 && SEGMENT.match?(value)
          end
          raise ArgumentError, "address is too long" if address.length > 48

          super(address: address.dup.freeze, owner_pub_dress: owner_pub_dress.dup.freeze, place: place.dup.freeze)
        end

        def station_pub_dress
          "#{owner_pub_dress}-#{place}"
        end
      end
    end
  end
end
