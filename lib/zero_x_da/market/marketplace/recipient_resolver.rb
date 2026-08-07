# frozen_string_literal: true

require_relative "../core/contracts"

module ZeroXDA
  module Market
    module Marketplace
      Recipient = Struct.new(
        :mode, :provider, :provider_user_id, :username, :eligibility,
        keyword_init: true
      ) do
        def to_h
          {
            "mode" => mode,
            "provider" => provider,
            "provider_user_id" => provider_user_id,
            "username" => username,
            "eligibility" => eligibility
          }.compact.freeze
        end
      end

      class RecipientResolver
        USERNAME_PATTERN = /\A[A-Za-z0-9_]{1,64}\z/

        def initialize(identities:)
          @identities = identities
        end

        def resolve(product:, actor_user_id:, recipient: nil)
          policy = product.metadata.dig("purchase", "recipient")
          return nil unless policy.is_a?(Hash)

          mode, username = recipient_input(recipient)
          modes = Array(policy.fetch("modes", ["self"])).map(&:to_s)
          unless modes.include?(mode)
            raise Core::Conflict.new(
              "recipient mode is not supported for this product",
              code: "recipient_mode_unsupported",
              details: { sku: product.sku, mode: mode }
            )
          end

          provider = policy.fetch("provider").to_s
          identity = mode == "self" ? self_identity(actor_user_id, provider) : username_identity(provider, username)
          resolved_username = mode == "self" ? identity&.provider_data&.fetch("username", nil).to_s : username
          if resolved_username.to_s.empty?
            raise Core::Conflict.new(
              "recipient requires a username",
              code: "recipient_username_required",
              details: { sku: product.sku, mode: mode }
            )
          end

          eligibility = evaluate_eligibility(product: product, policy: policy, identity: identity)
          Recipient.new(
            mode: mode,
            provider: provider,
            provider_user_id: identity&.provider_user_id,
            username: resolved_username,
            eligibility: eligibility
          ).freeze
        end

        private

        def recipient_input(value)
          document = value.nil? ? {} : value
          unless document.is_a?(Hash)
            raise ArgumentError, "recipient must be an object"
          end

          mode = document.fetch("mode", document.fetch(:mode, "self")).to_s
          raw_username = document["username"] || document[:username]
          username = normalize_username(raw_username) if raw_username
          if mode == "username" && username.to_s.empty?
            raise ArgumentError, "recipient username is required"
          end
          [mode, username]
        end

        def normalize_username(value)
          username = value.to_s.strip.delete_prefix("@")
          unless USERNAME_PATTERN.match?(username)
            raise ArgumentError, "recipient username is invalid"
          end
          username
        end

        def self_identity(actor_user_id, provider)
          identity = @identities.identities_for_user(actor_user_id.to_s).find { |item| item.provider == provider }
          return identity if identity

          raise Core::Conflict.new(
            "recipient identity is unavailable",
            code: "recipient_identity_unavailable",
            details: { provider: provider, mode: "self" }
          )
        end

        def username_identity(provider, username)
          matches = @identities.identities_by_provider_data(
            provider: provider,
            key: "username",
            value: username,
            case_insensitive: true
          )
          return nil if matches.empty?
          return matches.first if matches.length == 1

          raise Core::Conflict.new(
            "recipient username is ambiguous",
            code: "recipient_ambiguous",
            details: { provider: provider, username: username }
          )
        end

        def evaluate_eligibility(product:, policy:, identity:)
          requirements = policy["eligibility"]
          return { "status" => "not_required" }.freeze unless requirements.is_a?(Hash) && !requirements.empty?
          return { "status" => "unknown" }.freeze unless identity

          requirements.each do |key, expected|
            data = identity.provider_data
            return { "status" => "unknown", "field" => key.to_s }.freeze unless data.key?(key.to_s)

            actual = data[key.to_s]
            next if actual == expected

            code = policy.fetch("ineligible_code", "recipient_ineligible").to_s
            raise Core::Conflict.new(
              "recipient is not eligible for this product",
              code: code,
              details: {
                sku: product.sku,
                username: data["username"],
                field: key.to_s,
                expected: expected,
                actual: actual
              }.compact
            )
          end

          { "status" => "verified" }.freeze
        end
      end
    end
  end
end
