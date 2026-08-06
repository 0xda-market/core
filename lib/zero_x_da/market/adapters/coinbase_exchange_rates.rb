# frozen_string_literal: true

require "bigdecimal"
require "json"
require "net/http"
require "openssl"
require "timeout"
require "uri"
require_relative "../fx/rate_snapshot"

module ZeroXDA
  module Market
    module Adapters
      # Coinbase Data API adapter. The upstream endpoint returns units of each
      # target currency per one USDT; core stores the inverse, USDT per unit.
      class CoinbaseExchangeRates
        DEFAULT_ENDPOINT = "https://api.coinbase.com/v2/exchange-rates"
        DEFAULT_TIMEOUT_SECONDS = 10
        MAX_RESPONSE_BYTES = 2_097_152
        BASE_CURRENCY = "USDT"

        Response = Data.define(:status, :body)
        FetchError = Class.new(StandardError)

        attr_reader :key

        def initialize(
          endpoint: DEFAULT_ENDPOINT,
          timeout_seconds: DEFAULT_TIMEOUT_SECONDS,
          clock: -> { Time.now.utc },
          requester: nil
        )
          @endpoint = URI(endpoint)
          raise ArgumentError, "Coinbase FX endpoint must use HTTPS" unless @endpoint.is_a?(URI::HTTPS)

          @timeout_seconds = Integer(timeout_seconds)
          raise ArgumentError, "FX request timeout must be positive" unless @timeout_seconds.positive?

          @clock = clock
          @requester = requester || method(:request)
          @key = "coinbase"
        rescue URI::InvalidURIError, ArgumentError, TypeError
          raise ArgumentError, "Coinbase FX adapter configuration is invalid"
        end

        def fetch(currencies:)
          requested = normalize_currencies(currencies)
          response = @requester.call(request_uri)
          unless response.status.to_i.between?(200, 299)
            raise FetchError, "Coinbase FX request failed with status #{response.status}"
          end
          raise FetchError, "Coinbase FX response is too large" if response.body.to_s.bytesize > MAX_RESPONSE_BYTES

          document = JSON.parse(response.body)
          data = document.fetch("data")
          unless data.fetch("currency").to_s.upcase == BASE_CURRENCY
            raise FetchError, "Coinbase FX response has an unexpected base currency"
          end

          upstream = data.fetch("rates")
          rates = requested.to_h do |currency|
            units_per_usdt = positive_decimal(upstream.fetch(currency), currency: currency)
            [currency, BigDecimal("1") / units_per_usdt]
          end
          FX::RateSnapshot.new(provider: key, rates: rates, observed_at: observed_at)
        rescue KeyError, JSON::ParserError => error
          raise FetchError, "Coinbase FX response is incomplete: #{error.message}"
        end

        private

        def request_uri
          uri = @endpoint.dup
          uri.query = URI.encode_www_form(currency: BASE_CURRENCY)
          uri
        end

        def request(uri)
          request = Net::HTTP::Get.new(uri)
          request["accept"] = "application/json"
          request["user-agent"] = "0xda-market-core/fx-rates"
          response = Net::HTTP.start(
            uri.host,
            uri.port,
            use_ssl: true,
            open_timeout: @timeout_seconds,
            read_timeout: @timeout_seconds
          ) { |http| http.request(request) }
          Response.new(status: response.code.to_i, body: response.body.to_s)
        rescue Timeout::Error, SocketError, SystemCallError, IOError, EOFError,
               OpenSSL::SSL::SSLError => error
          raise FetchError, "Coinbase FX request failed: #{error.class}"
        end

        def normalize_currencies(values)
          currencies = Array(values).map { |value| value.to_s.strip.upcase }.uniq.sort
          if currencies.empty? || currencies.any? { |currency| !FX::RateSnapshot::CURRENCY_PATTERN.match?(currency) }
            raise ArgumentError, "FX currencies must be valid currency codes"
          end

          currencies.freeze
        end

        def positive_decimal(value, currency:)
          number = BigDecimal(value.to_s)
          raise ArgumentError unless number.finite? && number.positive?

          number
        rescue ArgumentError, TypeError
          raise FetchError, "Coinbase FX rate is invalid: #{currency}"
        end

        def observed_at
          value = @clock.call
          raise ArgumentError, "clock must return a Time" unless value.is_a?(Time)

          value.getutc
        end
      end
    end
  end
end
