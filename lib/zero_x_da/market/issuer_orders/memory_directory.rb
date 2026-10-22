# frozen_string_literal: true

require_relative "../core/contracts"

module ZeroXDA
  module Market
    module IssuerOrders
      # An in-process issuer directory for tests and local runs. It answers
      # like the issuer would: a public handle, or nil when the channel account
      # is not bound. With available: false every lookup is unavailable.
      class MemoryDirectory
        def initialize(bindings = {}, available: true, providers: [])
          @bindings = bindings.to_h { |(provider, user_id), handle| [[provider.to_s, user_id.to_s], handle] }
          @available = available
          @providers = providers
        end

        def supports?(provider)
          # An unconfigured directory is unavailable for every channel; it
          # must never masquerade as an issuer that says "not linked".
          !@available || @providers.include?(provider)
        end

        def bind(provider, provider_user_id, pub_dress)
          @bindings[[provider.to_s, provider_user_id.to_s]] = pub_dress
        end

        def lookup(provider:, provider_user_id:)
          unless @available
            raise Core::ProviderFailure.new("issuer directory is unavailable", code: "issuer_unavailable",
                                                                                 retryable: true)
          end

          @bindings[[provider.to_s, provider_user_id.to_s]]
        end
      end
    end
  end
end
