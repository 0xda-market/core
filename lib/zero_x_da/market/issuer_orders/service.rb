# frozen_string_literal: true

require "securerandom"
require "time"
require_relative "../core/contracts"
require_relative "order"

module ZeroXDA
  module Market
    module IssuerOrders
      # Orders paid in an issuer denomination. The market snapshots price and
      # recipient, then follows the issuer's asynchronous decision; it never
      # holds, debits or values the denomination itself.
      class Service
        MAX_PAGE = 100

        # One of the customer's channel accounts and the issuer account the
        # issuer's directory says it belongs to.
        Link = Data.define(:provider, :provider_user_id, :pub_dress)

        def initialize(store:, denominations:, users:, directory:, clock: -> { Time.now.utc },
                       id_generator: SecureRandom.method(:uuid))
          @store = store
          @denominations = denominations
          @users = users
          @directory = directory
          @clock = clock
          @id_generator = id_generator
        end

        # Returns [order, created]. Replaying the same idempotency key returns
        # the original order, even if the price or catalog changed since.
        def create(customer_user_id:, sku:, denomination:, idempotency_key:)
          customer = active_customer(customer_user_id)
          existing = @store.find_by_idempotency_key(customer_user_id: customer.id, idempotency_key: idempotency_key.to_s)
          return [replayed(existing, sku, denomination), false] if existing

          order = build_order(customer, sku.to_s, denomination.to_s, idempotency_key)
          event = event_for(order, from: nil, actor: "customer")
          persisted, created = @store.create(order, event: event)
          [created ? persisted : replayed(persisted, sku, denomination), created]
        end

        def find_for_customer(id, customer_user_id:)
          order = @store.find(id)
          raise Core::NotFound.new("issuer_order", id) unless order&.customer_user_id == customer_user_id.to_s

          order
        end

        # Only an unclaimed order can be cancelled, so a cancellation can never
        # race an issuer debit that is already in progress.
        def cancel(id, customer_user_id:)
          order = find_for_customer(id, customer_user_id: customer_user_id)
          return order if order.status == "cancelled"

          apply(order, order.cancel(at: now), actor: "customer")
        end

        # A page of the issuer's orders, oldest first. Returns [orders, cursor];
        # cursor is nil on the last page, otherwise it fetches the next one, so
        # a recovery scan reaches every order however long the backlog is.
        def queue(issuer:, status: "pending", limit: 50, cursor: nil)
          raise ArgumentError, "status is invalid" unless Order::STATUSES.include?(status)

          size = page_size(limit)
          orders = @store.list(issuer: issuer, status: status, limit: size, after: decode_cursor(cursor))
          last = orders.last
          [orders, orders.length == size && last ? "#{last.created_at.iso8601(6)},#{last.id}" : nil]
        end

        def find_for_issuer(id, issuer:)
          order = @store.find(id)
          raise Core::NotFound.new("issuer_order", id) unless order&.issuer == issuer

          order
        end

        def claim(id, issuer:)
          order = find_for_issuer(id, issuer: issuer)
          return order if order.status == "processing"

          apply(order, order.claim(at: now), actor: "issuer")
        end

        # The issuer confirms that it debited and granted exactly what was
        # ordered. Any difference fails closed and leaves the order unchanged.
        def fulfil(id, issuer:, reference:, amount_minor:, denomination:, recipient_subject:)
          order = find_for_issuer(id, issuer: issuer)
          reference = reference.to_s
          # Checked before the replay shortcut: a replay succeeds only for the
          # same complete confirmation, never for a conflicting one.
          expected = { "amount_minor" => order.amount_minor, "denomination" => order.denomination,
                       "recipient_subject" => order.recipient_subject }
          actual = { "amount_minor" => amount_minor, "denomination" => denomination,
                     "recipient_subject" => recipient_subject }
          mismatched = expected.keys.reject { |key| expected[key] == actual[key] }
          unless mismatched.empty?
            raise Core::Conflict.new("issuer confirmation does not match the order",
                                     code: "issuer_confirmation_mismatch", details: { id: order.id, fields: mismatched })
          end
          if order.status == "fulfilled"
            return order if order.issuer_reference == reference

            raise Core::Conflict.new("issuer order is already fulfilled with another reference",
                                     code: "issuer_reference_conflict", details: { id: order.id })
          end
          if (other = @store.find_by_issuer_reference(issuer: issuer, reference: reference))
            raise Core::Conflict.new("issuer reference is already used", code: "issuer_reference_conflict",
                                                                        details: { id: other.id })
          end

          apply(order, order.fulfil(reference: reference, at: now), actor: "issuer", data: { "reference" => reference })
        end

        def reject(id, issuer:, code:)
          order = find_for_issuer(id, issuer: issuer)
          return order if order.status == "rejected" && order.rejection_code == code

          apply(order, order.reject(code: code, at: now), actor: "issuer", data: { "code" => code })
        end

        def events(id)
          @store.events(id)
        end

        # Whether the customer's channel accounts lead to an issuer account.
        # A channel uses this to show the linked public handle, or to offer
        # signing in with the issuer to link one.
        def account_status(customer_user_id:, issuer:)
          # An issuer-scoped lookup must not label a 0x1 binding as belonging
          # to an arbitrary issuer supplied in the request path.
          unless @denominations.denominations.any? { |denomination| denomination.issuer == issuer }
            raise Core::NotFound.new("issuer", issuer)
          end
          customer = active_customer(customer_user_id)
          links = customer_links(customer)
          return { linked: false, issuer: issuer } if links.empty?

          link = single_account!(links, issuer)
          { linked: true, issuer: issuer, pub_dress: link.pub_dress, provider: link.provider }
        end

        private

        def build_order(customer, sku, code, idempotency_key)
          snapshot = @denominations.current_prices(denomination: code)
          denomination = snapshot.fetch(:denomination)
          entry = snapshot.fetch(:entries).find { |candidate| candidate.fetch(:product).sku == sku }
          unless entry
            raise Core::Conflict.new("product is not purchasable in this denomination",
                                     code: "denomination_price_unavailable", details: { sku: sku, denomination: code })
          end

          product = entry.fetch(:product)
          price = entry.fetch(:price)
          link = recipient_link(customer, product, denomination)
          Order.new(
            id: @id_generator.call, customer_user_id: customer.id, idempotency_key: idempotency_key,
            sku: product.sku, denomination: denomination.code, issuer: denomination.issuer,
            amount_minor: price.amount_minor, price_id: price.id, recipient_subject: link.pub_dress,
            link_provider: link.provider, link_provider_user_id: link.provider_user_id, created_at: now
          )
        end

        # The recipient is always the customer's own issuer account. The issuer
        # says which one, by looking up the customer's channel accounts in its
        # directory. The product must name the issuer as its recipient.
        def recipient_link(customer, product, denomination)
          policy = product.metadata.dig("purchase", "recipient")
          unless policy.is_a?(Hash) && policy["provider"] == denomination.issuer &&
                 Array(policy.fetch("modes", ["self"])).include?("self")
            raise Core::Conflict.new("product is not delivered to the denomination issuer",
                                     code: "recipient_mode_unsupported", details: { sku: product.sku })
          end

          links = customer_links(customer)
          return single_account!(links, denomination.issuer) unless links.empty?

          raise Core::Conflict.new("customer has no linked issuer account", code: "issuer_account_unlinked",
                                                                          details: { issuer: denomination.issuer })
        end

        # Asks the issuer about each of the customer's channel accounts it
        # binds. A directory that cannot answer raises issuer_unavailable;
        # it is never read as "not linked".
        def customer_links(customer)
          @users.identities_for_user(customer.id).filter_map do |identity|
            next unless @directory.supports?(identity.provider)

            pub_dress = @directory.lookup(provider: identity.provider, provider_user_id: identity.provider_user_id)
            pub_dress && Link.new(provider: identity.provider, provider_user_id: identity.provider_user_id,
                                  pub_dress: pub_dress)
          end
        end

        # Two channel accounts linked to different issuer accounts leave the
        # recipient ambiguous; the market never guesses whose balance to debit.
        def single_account!(links, issuer)
          return links.min_by(&:provider) if links.map(&:pub_dress).uniq.length == 1

          raise Core::Conflict.new("customer channel accounts link to different issuer accounts",
                                   code: "recipient_ambiguous", details: { issuer: issuer })
        end

        def replayed(order, sku, denomination)
          return order if order.sku == sku.to_s && order.denomination == denomination.to_s

          raise Core::Conflict.new("idempotency key was used for a different order", code: "idempotency_conflict",
                                                                                   details: { id: order.id })
        end

        def active_customer(user_id)
          user = @users.find_user(user_id.to_s)
          raise Core::NotFound.new("user", user_id) unless user
          raise Core::Forbidden.new("user is not active") unless user.status == "active"

          user
        end

        def apply(current, changed, actor:, data: {})
          event = event_for(changed, from: current.status, actor: actor, data: data)
          @store.replace(changed, expected_version: current.version, event: event)
        end

        def event_for(order, from:, actor:, data: {})
          Event.new(order_id: order.id, from_status: from, to_status: order.status, actor: actor,
                    data: data, created_at: order.updated_at)
        end

        def decode_cursor(cursor)
          return nil if cursor.nil? || cursor.to_s.empty?

          timestamp, id = cursor.to_s.split(",", 2)
          raise ArgumentError unless id&.match?(/\A[A-Za-z0-9-]{1,64}\z/)

          [Time.iso8601(timestamp).getutc, id]
        rescue ArgumentError, TypeError
          raise ArgumentError, "cursor is invalid"
        end

        def page_size(value)
          limit = Integer(value)
          raise ArgumentError unless (1..MAX_PAGE).cover?(limit)

          limit
        rescue ArgumentError, TypeError
          raise ArgumentError, "limit must be between 1 and #{MAX_PAGE}"
        end

        def now
          value = @clock.call
          raise ArgumentError, "clock must return a Time" unless value.is_a?(Time)

          # Microseconds, as stored, so a returned order equals its re-read.
          value.getutc.floor(6)
        end
      end
    end
  end
end
