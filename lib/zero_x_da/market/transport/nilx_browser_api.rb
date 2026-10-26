# frozen_string_literal: true
# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT

require "json"
require "digest"
require "securerandom"
require "rack"
require_relative "bearer_auth"

module ZeroXDA
  module Market
    module Transport
      # Mounted at /nilx-browser. Only the trusted 0x1 server can issue a
      # handoff; only a form posted from the 0x1 origin can redeem it.
      # This session conveys identity and display context, never debit authority.
      class NilxBrowserAPI
        COOKIE = "__Host-market_nilx"
        SOURCE = "https://nilx.one"
        TARGET = "https://0xda-market.nilx.one"

        def initialize(store:, identity_service:, token:, clock: -> { Time.now.to_i })
          raise ArgumentError, "handoff token must have at least 32 bytes" if token.to_s.bytesize < 32

          @store, @identity, @clock = store, identity_service, clock
          @auth = BearerAuth.new(token: token)
        end

        def call(env)
          request = Rack::Request.new(env)
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
            response(200, context.reject { |key, _| %w[subject market_user_id].include?(key) })
          else
            response(404, error: "not_found")
          end
        rescue JSON::ParserError, KeyError, ArgumentError, TypeError
          response(422, error: "invalid_handoff")
        end

        private

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

          { "subject" => subject, "point" => point, "seeds" => seeds,
            "seeds_authority" => authority, "avaia" => { "longitude" => lng, "latitude" => lat },
            "category" => "0x1" }
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
