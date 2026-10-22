# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "timeout"
require "uri"
require_relative "../core/contracts"

module ZeroXDA
  module Market
    module Adapters
      # Asks an issuer which of its accounts a channel account belongs to,
      # through the issuer's partner lookup endpoint. The issuer answers with
      # the account's public handle, or that the person must sign in with the
      # issuer to connect it. The market keeps no copy of the issuer's bindings.
      #
      # An answer the issuer could not give (timeout, error status, malformed
      # body) is never read as "not linked": it raises issuer_unavailable, so a
      # person is never sent to link an account that may already be linked.
      class IssuerDirectoryHTTP
        DEFAULT_TIMEOUT_SECONDS = 5
        MAX_RESPONSE_BYTES = 16_384

        Response = Data.define(:status, :body)

        def initialize(endpoint:, token:, providers:, timeout_seconds: DEFAULT_TIMEOUT_SECONDS, requester: nil)
          @endpoint = URI(endpoint)
          raise ArgumentError unless @endpoint.is_a?(URI::HTTPS)

          @providers = Array(providers).map { |provider| Core::RecordSupport.identifier(provider, field: "provider") }
          raise ArgumentError if @providers.empty?

          @token = Core::RecordSupport.identifier(token, field: "issuer directory token")
          @timeout_seconds = Integer(timeout_seconds)
          raise ArgumentError unless @timeout_seconds.positive?

          @requester = requester || method(:request)
        rescue URI::InvalidURIError, ArgumentError, TypeError
          raise ArgumentError, "issuer directory configuration is invalid"
        end

        # Whether the issuer binds accounts of this provider at all.
        def supports?(provider)
          @providers.include?(provider)
        end

        # The issuer account's public handle, or nil when the account is not
        # bound to any issuer account.
        def lookup(provider:, provider_user_id:)
          response = @requester.call(@endpoint, @token,
                                     JSON.generate(provider: provider, subject: provider_user_id.to_s))
          raise unavailable("status #{response.status}") unless response.status.to_i == 200
          raise unavailable("response is too large") if response.body.to_s.bytesize > MAX_RESPONSE_BYTES

          document = JSON.parse(response.body)
          case document["state"]
          when "linked" then pub_dress(document["pub_dress"])
          when "sign_in_required" then nil
          else raise unavailable("unknown answer")
          end
        rescue JSON::ParserError, TypeError
          raise unavailable("malformed answer")
        end

        private

        def pub_dress(value)
          raise unavailable("malformed handle") unless value.is_a?(String) && value.length.between?(1, 128)

          value
        end

        def unavailable(reason)
          Core::ProviderFailure.new("issuer directory is unavailable: #{reason}",
                                    code: "issuer_unavailable", retryable: true)
        end

        def request(uri, token, body)
          request = Net::HTTP::Post.new(uri)
          request["authorization"] = "Bearer #{token}"
          request["content-type"] = "application/json"
          request["accept"] = "application/json"
          request["user-agent"] = "0xda-market-core/issuer-directory"
          request.body = body
          response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                                         open_timeout: @timeout_seconds,
                                                         read_timeout: @timeout_seconds) { |http| http.request(request) }
          Response.new(status: response.code.to_i, body: response.body.to_s)
        rescue Timeout::Error, SocketError, SystemCallError, IOError, EOFError, OpenSSL::SSL::SSLError => error
          raise unavailable(error.class.name)
        end
      end
    end
  end
end
