# frozen_string_literal: true
# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT

require "json"
require "digest"
require "securerandom"
require "rack"
require_relative "bearer_auth"
require_relative "issuer_order_presenter"
require_relative "../issuer_orders/service"

module ZeroXDA
  module Market
    module Transport
      # Mounted at /nilx-browser. Only the trusted 0x1 server can issue a
      # handoff; only a form posted from the 0x1 origin can redeem it.
      # This session conveys identity and display context, never debit authority.
      class NilxBrowserAPI
        include IssuerOrderPresenter
        COOKIE = "__Host-market_nilx"
        SOURCE = "https://nilx.one"
        TARGET = "https://0xda-market.nilx.one"

        def initialize(store:, identity_service:, token:, clock: -> { Time.now.to_i }, issuer_orders: nil, denominations: nil)
          raise ArgumentError, "handoff token must have at least 32 bytes" if token.to_s.bytesize < 32

          @store, @identity, @clock = store, identity_service, clock
          @auth = BearerAuth.new(token: token)
          @orders, @denominations = issuer_orders, denominations
        end

        def call(env)
          request = Rack::Request.new(env)
          if request.path_info == "/offers" || request.path_info.start_with?("/orders")
            return checkout(request)
          end
          case [request.request_method, request.path_info]
          when ["POST", "/handoffs"]
            return response(401, error: "unauthorized") unless @auth.authorized?(request)

            body = JSON.parse(request.body.read(8193))
            context = validate(body)
            code = SecureRandom.urlsafe_base64(32)
            @store.put(digest(code), "handoff", context, @clock.call + 60)
            response(201, code: code, action: "#{TARGET}/nilx-browser/exchange", expires_in: 60)
          when ["POST", "/exchange"]
            return response(403, error: "origin_rejected") unless request.get_header("HTTP_ORIGIN") == SOURCE
            return response(415, error: "form_required") unless request.media_type == "application/x-www-form-urlencoded"

            form = Rack::Utils.parse_query(request.body.read(1025))
            code = form.fetch("code", "")
            return response(400, error: "invalid_code") unless code.match?(/\A[A-Za-z0-9_-]{43}\z/)

            context = @store.consume(digest(code), "handoff", @clock.call)
            return response(401, error: "handoff_expired") unless context

            auth = @identity.authenticate(provider: "nilx", provider_user_id: context.fetch("subject"))
            session = SecureRandom.urlsafe_base64(32)
            @store.put(digest(session), "session", context.merge("market_user_id" => auth.user.id), @clock.call + 1800)
            headers = {
              "location" => "#{TARGET}/#{Rack::Utils.escape_path(context.fetch('point'))}",
              "set-cookie" => "#{COOKIE}=#{session}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=1800"
            }
            response(303, {}, headers)
          when ["GET", "/session"]
            token = request.cookies[COOKIE].to_s
            context = @store.read(digest(token), "session", @clock.call)
            return response(401, error: "session_required") unless context

            # Pairwise identity is server-only; the browser needs just view context.
            response(200, context.reject { |key, _| %w[subject market_user_id recipient].include?(key) })
          else
            response(404, error: "not_found")
          end
        rescue JSON::ParserError, KeyError, ArgumentError, TypeError
          response(422, error: "invalid_handoff")
        rescue Core::NotFound
          response(404, error: "not_found")
        rescue Core::Conflict => error
          response(409, error: error.code)
        rescue Core::Forbidden
          response(403, error: "forbidden")
        end

        private

        SPECIAL = %w[0x1_special_1m 0x1_special_3m 0x1_special_6m 0x1_special_12m].freeze

        def checkout(request)
          return response(503, error: "checkout_unavailable") unless @orders && @denominations
          context = @store.read(digest(request.cookies[COOKIE].to_s), "session", @clock.call)
          return response(401, error: "session_required") unless context && context["visit_id"] && context["recipient"]
          if request.request_method == "POST"
            return response(403, error: "origin_rejected") unless request.get_header("HTTP_ORIGIN") == TARGET
            return response(403, error: "csrf_required") unless request.get_header("HTTP_X_MARKET_CSRF") == "1"
            return response(415, error: "json_required") unless request.media_type == "application/json"
          end
          if request.get? && request.path_info == "/offers"
            snapshot = @denominations.current_prices(denomination: "seeds")
            offers = snapshot.fetch(:entries).filter_map do |entry|
              product, price = entry.values_at(:product, :price)
              next unless SPECIAL.include?(product.sku) && product.system_broker?
              { sku: product.sku, price_id: price.id, amount_minor: price.amount_minor,
                denomination: "seeds", months: product.metadata["duration_months"],
                term_policy: IssuerOrders::Order::TERM_POLICY,
                authorization_ttl_seconds: IssuerOrders::Service::AUTHORIZATION_TTL }
            end
            return response(200, offers: offers)
          end
          if request.post? && request.path_info == "/orders"
            body = JSON.parse(request.body.read(4097))
            raise ArgumentError unless body.is_a?(Hash) &&
              body.keys.sort == %w[amount_minor idempotency_key price_id sku] && SPECIAL.include?(body["sku"])
            link = IssuerOrders::Service::Link.new(provider: "nilx_visit",
              provider_user_id: context.fetch("visit_id"), pub_dress: context.fetch("recipient"))
            order, created = @orders.create(customer_user_id: context.fetch("market_user_id"),
              sku: body.fetch("sku"), denomination: "seeds", idempotency_key: body.fetch("idempotency_key"),
              verified_link: link, expected_price: [body.fetch("price_id"), body.fetch("amount_minor")])
            return order_response(created ? 201 : 200, order)
          end
          match = %r{\A/orders/([A-Za-z0-9._:-]{1,128})(/cancel)?\z}.match(request.path_info)
          return response(404, error: "not_found") unless match
          id, cancel = match.captures
          if request.post? && cancel
            order = @orders.cancel(id, customer_user_id: context.fetch("market_user_id"))
          elsif request.get? && !cancel
            order = @orders.find_for_customer(id, customer_user_id: context.fetch("market_user_id"))
          else
            return response(404, error: "not_found")
          end
          order_response(200, order)
        end

        def order_response(status, order)
          response(status, order: present_issuer_order(order, audience: :customer),
            visit_id: order.link_provider == "nilx_visit" ? order.link_provider_user_id : nil)
        end

        def validate(body)
          raise ArgumentError unless body.is_a?(Hash)
          subject = body.fetch("subject")
          point = body.fetch("point")
          seeds = body.fetch("seeds")
          # Only a token-authenticated 0x1 server may attest to an issuer
          # wallet snapshot. A missing field keeps legacy display-only context.
          authority = body.fetch("seeds_authority", "client_display")
          raise ArgumentError unless %w[client_display identity_snapshot].include?(authority)
          avaia = body.fetch("avaia")
          raise ArgumentError unless subject.is_a?(String) && subject.match?(/\A[a-f0-9]{64}\z/)
          raise ArgumentError unless point.is_a?(String) && point.match?(/\A[\p{L}\p{N}][\p{L}\p{N}_-]{0,63}\z/u)
          raise ArgumentError unless seeds.is_a?(String) && seeds.match?(/\A(?:0|[1-9][0-9]{0,19})\z/)
          raise ArgumentError unless avaia.is_a?(Hash)
          lng, lat = avaia.values_at("longitude", "latitude")
          raise ArgumentError unless [lng, lat].all? { |v| v.is_a?(Numeric) && v.finite? }
          raise ArgumentError unless (-180..180).cover?(lng) && (-90..90).cover?(lat)

          scene = body["scene"]
          raise ArgumentError if scene && (!scene.is_a?(Hash) || JSON.generate(scene).bytesize > 6000)
          camera = body["camera"]
          if camera
            raise ArgumentError unless camera.is_a?(Hash) && camera.keys.sort == %w[bearing center pitch zoom] &&
              camera["center"].is_a?(Array) && camera["center"].length == 2 &&
              [*camera["center"], camera["zoom"], camera["bearing"], camera["pitch"]].all? { |v| v.is_a?(Numeric) && v.finite? } &&
              (-180..180).cover?(camera["center"][0]) && (-90..90).cover?(camera["center"][1]) &&
              (0..24).cover?(camera["zoom"]) && (0..85).cover?(camera["pitch"])
          end
          purchase = {}
          if body.key?("visit_id") || body.key?("recipient") || body.key?("return_path")
            visit = body.fetch("visit_id")
            recipient = body.fetch("recipient")
            return_path = body.fetch("return_path")
            raise ArgumentError unless visit.is_a?(String) && visit.match?(/\A[A-Za-z0-9_-]{43}\z/) &&
              recipient.is_a?(String) && recipient.length.between?(1, 128) &&
              return_path.is_a?(String) && return_path.match?(/\A\/(?:[a-z0-9-]+\/)?\z/)
            purchase = { "visit_id" => visit, "recipient" => recipient, "return_path" => return_path }
          end
          { "subject" => subject, "point" => point, "seeds" => seeds,
            "seeds_authority" => authority, "avaia" => { "longitude" => lng, "latitude" => lat },
            "category" => "0x1" }.merge(purchase).merge(camera ? { "camera" => camera } : {}).merge(scene ? { "scene" => scene } : {})
        end

        def digest(value)
          Digest::SHA256.hexdigest(value)
        end

        def response(status, body = {}, extra = {})
          [status, { "content-type" => "application/json", "cache-control" => "no-store",
                     "referrer-policy" => "no-referrer" }.merge(extra), [JSON.generate(body)]]
        end
      end
    end
  end
end
