# frozen_string_literal: true

require "json"
require "openssl"
require "rack"

module ZeroXDA
  module Market
    module Transport
      # Verified customer ingress for a trusted channel adapter that runs in its
      # own process, such as a messenger bot.
      #
      # The adapter validates the provider's own login proof (for example a
      # provider-signed webhook update or web app payload), resolves the market user through
      # `POST /v1/auth/external`, and then signs a short-lived assertion for
      # that user and channel account:
      #
      #   X-Market-Customer-Assertion: v1.<base64url(JSON)>.<hex HMAC-SHA256>
      #
      # The JSON carries `user_id`, `provider`, `provider_user_id`, `iat` and
      # `exp` (Unix seconds). The MAC covers `zero-x-da-market-customer-v1.` and
      # the encoded payload, keyed by `CHANNEL_ASSERTION_SECRET`.
      #
      # This middleware sets `zero_x_da.market.verified_customer_id` only when
      # the MAC matches, the assertion is fresh and short-lived, the provider is
      # one this deployment accepts, and the market's own identity store says
      # that channel account belongs to that active user. Anything else leaves
      # the context unset, so customer routes answer 401. A header can never
      # set the Rack key directly; any value already present is discarded.
      class ChannelCustomerAssertion
        HEADER = "HTTP_X_MARKET_CUSTOMER_ASSERTION"
        CONTEXT = "zero_x_da.market.verified_customer_id"
        DOMAIN = "zero-x-da-market-customer-v1."
        VERSION = "v1"
        MIN_SECRET_BYTES = 32
        MAX_LIFETIME = 120
        MAX_SKEW = 30
        MAX_HEADER_BYTES = 1024

        def self.sign(secret:, user_id:, provider:, provider_user_id:, now:, lifetime: 60)
          payload = encode(JSON.generate({ "user_id" => user_id.to_s, "provider" => provider.to_s,
                                           "provider_user_id" => provider_user_id.to_s,
                                           "iat" => now.to_i, "exp" => now.to_i + lifetime }))
          "#{VERSION}.#{payload}.#{OpenSSL::HMAC.hexdigest("SHA256", secret, DOMAIN + payload)}"
        end

        # Unpadded base64url, as RFC 7515 uses it.
        def self.encode(bytes)
          [bytes].pack("m0").tr("+/", "-_").delete("=")
        end

        def self.decode(text)
          raise ArgumentError, "not base64url" unless text.match?(/\A[A-Za-z0-9_-]*\z/)

          padded = text.tr("-_", "+/")
          padded += "=" * (-padded.length % 4)
          padded.unpack1("m0")
        end

        def initialize(app, secret:, users:, providers:, clock: -> { Time.now.utc })
          raise ArgumentError, "channel assertion secret is too short" if secret.to_s.bytesize < MIN_SECRET_BYTES
          raise ArgumentError, "channel assertion providers are required" if Array(providers).empty?

          @app = app
          @secret = secret.to_s
          @users = users
          @providers = Array(providers).map(&:to_s).freeze
          @clock = clock
        end

        def call(environment)
          environment.delete(CONTEXT)
          user_id = verified_user_id(environment[HEADER])
          environment[CONTEXT] = user_id if user_id
          @app.call(environment)
        end

        private

        def verified_user_id(header)
          return nil unless header.is_a?(String) && header.bytesize <= MAX_HEADER_BYTES

          version, payload, mac = header.split(".", 3)
          return nil unless version == VERSION && payload && mac&.match?(/\A[0-9a-f]{64}\z/)

          expected = OpenSSL::HMAC.hexdigest("SHA256", @secret, DOMAIN + payload)
          return nil unless Rack::Utils.secure_compare(expected, mac)

          claims = decode(payload)
          return nil unless claims && fresh?(claims)

          owner(claims)
        end

        def decode(payload)
          claims = JSON.parse(self.class.decode(payload))
          claims.is_a?(Hash) ? claims : nil
        rescue ArgumentError, JSON::ParserError
          nil
        end

        def fresh?(claims)
          issued = claims["iat"]
          expires = claims["exp"]
          return false unless issued.is_a?(Integer) && expires.is_a?(Integer)

          now = @clock.call.to_i
          expires > issued && expires - issued <= MAX_LIFETIME && issued <= now + MAX_SKEW && now < expires
        end

        # The channel account must be one the market already knows, owned by
        # the asserted active user.
        def owner(claims)
          provider = claims["provider"]
          subject = claims["provider_user_id"]
          user_id = claims["user_id"]
          return nil unless @providers.include?(provider)
          return nil unless [subject, user_id].all? { |value| value.is_a?(String) && !value.empty? }

          identity = @users.find_identity(provider: provider, provider_user_id: subject)
          return nil unless identity && identity.user_id == user_id

          user = @users.find_user(user_id)
          user && user.status == "active" ? user.id : nil
        end
      end
    end
  end
end
