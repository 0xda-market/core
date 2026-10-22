# frozen_string_literal: true

require_relative "../core/contracts"
require_relative "../core/records"

module ZeroXDA
  module Market
    module IssuerOrders
      # The issuer's assertion that a channel account (for example a messenger
      # account) is bound to one of its accounts. Only the issuer writes it;
      # the market uses it to find whose issuer balance an order debits.
      class AccountLink
        PROVIDER_PATTERN = /\A[a-z][a-z0-9._-]{0,63}\z/

        attr_reader :issuer, :provider, :provider_user_id, :subject, :pub_dress, :linked_at, :updated_at

        def initialize(issuer:, provider:, provider_user_id:, subject:, pub_dress:, linked_at:, updated_at: linked_at)
          @issuer = Core::RecordSupport.identifier(issuer, field: "issuer")
          raise ArgumentError, "provider is invalid" unless provider.is_a?(String) && PROVIDER_PATTERN.match?(provider)

          @provider = provider.dup.freeze
          @provider_user_id = bounded(provider_user_id, 256, field: "provider_user_id")
          @subject = bounded(subject, 256, field: "subject")
          # pub_dress is the issuer's public handle, kept opaque: its grammar
          # (Unicode, URI-reserved characters) belongs to the issuer.
          @pub_dress = bounded(pub_dress, 128, field: "pub_dress")
          raise ArgumentError, "pub_dress must not contain control characters" if @pub_dress.match?(/[[:cntrl:]]/)

          @linked_at = Core::RecordSupport.time(linked_at, field: "linked_at")
          @updated_at = Core::RecordSupport.time(updated_at, field: "updated_at")
          freeze
        end

        # Raised when another channel account of the same provider already holds
        # this issuer account: the issuer must unlink it first.
        def self.conflict(link)
          Core::Conflict.new(
            "issuer account is already linked to another #{link.provider} account",
            code: "issuer_account_link_conflict",
            details: { issuer: link.issuer, provider: link.provider, pub_dress: link.pub_dress }
          )
        end

        def to_h
          { issuer: @issuer, provider: @provider, provider_user_id: @provider_user_id, subject: @subject,
            pub_dress: @pub_dress, linked_at: @linked_at, updated_at: @updated_at }
        end

        private

        def bounded(value, maximum, field:)
          value = value.to_s if value.is_a?(Integer)
          unless value.is_a?(String) && value.length.between?(1, maximum)
            raise ArgumentError, "#{field} must be 1 to #{maximum} characters"
          end

          value.dup.freeze
        end
      end
    end
  end
end
