# frozen_string_literal: true

require "bigdecimal"

module ZeroXDA
  module Market
    module Bootstrap
      class Reconciler
        REQUIRED_SKUS = %w[
          premium_3m premium_6m premium_9m
          stars_500 stars_1000 stars_3000
        ].freeze

        def initialize(pricing:, listings:, actor_user_id:)
          @pricing = pricing
          @listings = listings
          @actor_user_id = actor_user_id.to_s
          raise ArgumentError, "actor_user_id must be present" if @actor_user_id.empty?
        end

        def reconcile(manifest)
          products = normalize_manifest(manifest)
          price_changes = reconcile_prices(products)
          listing_changes = reconcile_listings(products)

          {
            "status" => "ok",
            "prices" => price_changes,
            "listings" => listing_changes
          }.freeze
        end

        private

        def normalize_manifest(manifest)
          source = manifest.respond_to?(:to_h) ? manifest.to_h : nil
          raise ArgumentError, "manifest must be an object" unless source

          rows = source["products"] || source[:products]
          raise ArgumentError, "manifest products must be an array" unless rows.is_a?(Array)

          products = rows.map { |row| normalize_product(row) }
          skus = products.map { |row| row.fetch("sku") }
          raise ArgumentError, "manifest contains duplicate skus" unless skus.uniq.length == skus.length

          missing = REQUIRED_SKUS - skus
          extra = skus - REQUIRED_SKUS
          raise ArgumentError, "manifest is missing skus: #{missing.join(', ')}" unless missing.empty?
          raise ArgumentError, "manifest contains unsupported skus: #{extra.join(', ')}" unless extra.empty?

          products.freeze
        end

        def normalize_product(row)
          row = row.to_h.transform_keys(&:to_s)
          supply = row.fetch("supply").to_h.transform_keys(&:to_s)
          {
            "sku" => non_empty(row.fetch("sku"), "sku"),
            "sale_price_usdt" => decimal(row.fetch("sale_price_usdt"), "sale_price_usdt"),
            "supply" => {
              "quantity" => decimal(supply.fetch("quantity"), "quantity"),
              "price_amount" => decimal(supply.fetch("price_amount"), "price_amount"),
              "currency" => non_empty(supply.fetch("currency"), "currency").upcase
            }.freeze
          }.freeze
        rescue KeyError => error
          raise ArgumentError, "manifest field is missing: #{error.key}"
        end

        def reconcile_prices(products)
          current = @pricing.current_prices
          changes = products.filter_map do |product|
            existing = current[product.fetch("sku")]
            desired = product.fetch("sale_price_usdt")
            next if existing && existing.amount_usdt == desired

            { "sku" => product.fetch("sku"), "amount_usdt" => desired.to_s("F") }
          end
          return { "changed" => 0, "skus" => [] }.freeze if changes.empty?

          @pricing.apply_prices(
            changes,
            source: "admin",
            set_by_user_id: @actor_user_id,
            expected_revision: @pricing.current_revision
          )
          { "changed" => changes.length, "skus" => changes.map { |entry| entry.fetch("sku") } }.freeze
        end

        def reconcile_listings(products)
          owned = @listings.list_owned(actor_user_id: @actor_user_id)
          by_sku = owned.group_by(&:sku)
          ambiguous = by_sku.select { |_sku, rows| rows.length > 1 }.keys
          unless ambiguous.empty?
            raise ArgumentError, "multiple active broker listings for skus: #{ambiguous.sort.join(', ')}"
          end

          created = []
          updated = []
          unchanged = []

          products.each do |product|
            desired = product.fetch("supply")
            current = by_sku.fetch(product.fetch("sku"), []).first
            if current.nil?
              @listings.create(
                actor_user_id: @actor_user_id,
                sku: product.fetch("sku"),
                quantity: desired.fetch("quantity").to_s("F"),
                price_amount: desired.fetch("price_amount").to_s("F"),
                currency: desired.fetch("currency")
              )
              created << product.fetch("sku")
            elsif listing_matches?(current, desired)
              unchanged << product.fetch("sku")
            else
              @listings.update(
                actor_user_id: @actor_user_id,
                listing_id: current.id,
                quantity: desired.fetch("quantity").to_s("F"),
                price_amount: desired.fetch("price_amount").to_s("F"),
                currency: desired.fetch("currency"),
                expected_version: current.version
              )
              updated << product.fetch("sku")
            end
          end

          {
            "created" => created,
            "updated" => updated,
            "unchanged" => unchanged
          }.freeze
        end

        def listing_matches?(listing, desired)
          listing.quantity == desired.fetch("quantity") &&
            listing.price_amount == desired.fetch("price_amount") &&
            listing.currency == desired.fetch("currency")
        end

        def decimal(value, field)
          number = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
          raise ArgumentError, "#{field} must be positive" unless number.finite? && number.positive?

          number
        rescue ArgumentError
          raise ArgumentError, "#{field} must be a positive decimal"
        end

        def non_empty(value, field)
          string = value.to_s.strip
          raise ArgumentError, "#{field} must be present" if string.empty?

          string
        end
      end
    end
  end
end
