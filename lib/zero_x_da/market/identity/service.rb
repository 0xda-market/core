# frozen_string_literal: true

require "securerandom"
require_relative "../core/contracts"
require_relative "records"

module ZeroXDA
  module Market
    module Identity
      class Service
        PROVIDER_PATTERN = /\A[a-z][a-z0-9._-]{0,63}\z/
        PROVIDER_DATA_KEY_PATTERN = /\A[a-zA-Z][a-zA-Z0-9._-]{0,63}\z/
        AUTHENTICATABLE_ROLES = %w[client broker].freeze
        ROLE_RANK = { "client" => 0, "broker" => 1, "admin" => 2 }.freeze

        def initialize(
          store:,
          clock: -> { Time.now.utc },
          id_generator: SecureRandom.method(:uuid)
        )
          @store = store
          @clock = clock
          @id_generator = id_generator
        end

        def authenticate(provider:, provider_user_id:, provider_data: {}, role: "client")
          provider = normalize_provider(provider)
          provider_user_id = normalize_provider_user_id(provider_user_id)
          provider_data = Core::RecordSupport.document(provider_data, field: "provider data")
          role = normalize_role(role)
          attempts = 0

          begin
            authenticate_once(provider, provider_user_id, provider_data, role)
          rescue Core::Conflict => error
            raise unless error.code == "duplicate_identity" && attempts.zero?

            attempts += 1
            retry
          end
        end

        def active_users
          @store.list_users(status: "active")
        end

        def find_profile_by_external_identity(
          provider:,
          provider_user_id: nil,
          provider_data_key: nil,
          provider_data_value: nil,
          case_insensitive: false
        )
          provider = normalize_provider(provider)
          selector = normalize_lookup_selector(
            provider_user_id: provider_user_id,
            provider_data_key: provider_data_key,
            provider_data_value: provider_data_value,
            case_insensitive: case_insensitive
          )

          @store.transaction do |store|
            identity = lookup_identity(store, provider, selector)
            raise Core::NotFound.new("external_identity", lookup_reference(provider, selector)) unless identity

            user = store.find_user(identity.user_id) || raise(Core::NotFound.new("user", identity.user_id))
            UserProfile.new(
              user: user,
              identities: store.identities_for_user(user.id).freeze
            )
          end
        end

        private

        def authenticate_once(provider, provider_user_id, provider_data, role)
          @store.transaction do |store|
            identity = store.find_identity(
              provider: provider,
              provider_user_id: provider_user_id
            )

            if identity
              authenticate_existing(store, identity, provider_data, role)
            else
              create_user_and_identity(store, provider, provider_user_id, provider_data, role)
            end
          end
        end

        def authenticate_existing(store, identity, provider_data, role)
          user = fetch_active_user(store, identity.user_id)
          user = assign_role(store, user, role)

          now = current_time
          replacement = ExternalIdentity.new(
            id: identity.id,
            user_id: identity.user_id,
            provider: identity.provider,
            provider_user_id: identity.provider_user_id,
            provider_data: provider_data,
            created_at: identity.created_at,
            updated_at: now,
            last_authenticated_at: now,
            version: identity.version + 1
          )
          replacement = store.replace_identity(replacement, expected_version: identity.version)
          Authentication.new(user: user, identity: replacement, created: false)
        end

        def create_user_and_identity(store, provider, provider_user_id, provider_data, role)
          now = current_time
          user = User.new(
            id: new_id,
            role: role,
            status: "active",
            created_at: now
          )
          identity = ExternalIdentity.new(
            id: new_id,
            user_id: user.id,
            provider: provider,
            provider_user_id: provider_user_id,
            provider_data: provider_data,
            created_at: now
          )

          store.insert_user(user)
          store.insert_identity(identity)
          Authentication.new(user: user, identity: identity, created: true)
        end

        def lookup_identity(store, provider, selector)
          if selector.key?(:provider_user_id)
            return store.find_identity(
              provider: provider,
              provider_user_id: selector.fetch(:provider_user_id)
            )
          end

          identities = store.identities_by_provider_data(
            provider: provider,
            key: selector.fetch(:provider_data_key),
            value: selector.fetch(:provider_data_value),
            case_insensitive: selector.fetch(:case_insensitive)
          )
          return identities.first if identities.length == 1
          return nil if identities.empty?

          raise Core::Conflict.new(
            "external identity selector is ambiguous",
            code: "ambiguous_external_identity",
            details: {
              provider: provider,
              provider_data_key: selector.fetch(:provider_data_key),
              matches: identities.length
            }
          )
        end

        def normalize_lookup_selector(
          provider_user_id:,
          provider_data_key:,
          provider_data_value:,
          case_insensitive:
        )
          has_provider_user_id = !provider_user_id.nil? && !provider_user_id.to_s.empty?
          has_provider_data = !provider_data_key.nil? || !provider_data_value.nil?
          unless has_provider_user_id ^ has_provider_data
            raise ArgumentError, "provide exactly one external identity selector"
          end

          if has_provider_user_id
            unless case_insensitive == false
              raise ArgumentError, "case_insensitive is only valid for provider data lookup"
            end

            return { provider_user_id: normalize_provider_user_id(provider_user_id) }.freeze
          end

          unless provider_data_key && provider_data_value
            raise ArgumentError, "provider_data_key and provider_data_value are required together"
          end
          unless case_insensitive == true || case_insensitive == false
            raise ArgumentError, "case_insensitive must be boolean"
          end

          {
            provider_data_key: normalize_provider_data_key(provider_data_key),
            provider_data_value: normalize_provider_data_value(provider_data_value),
            case_insensitive: case_insensitive
          }.freeze
        end

        def lookup_reference(provider, selector)
          if selector.key?(:provider_user_id)
            "#{provider}:#{selector.fetch(:provider_user_id)}"
          else
            "#{provider}:#{selector.fetch(:provider_data_key)}=#{selector.fetch(:provider_data_value)}"
          end
        end

        def fetch_active_user(store, id)
          user = store.find_user(id) || raise(Core::NotFound.new("user", id))
          if user.status != "active"
            raise Core::Conflict.new(
              "user is not active",
              code: "user_not_active",
              details: { user_id: user.id }
            )
          end
          user
        end

        def assign_role(store, user, role)
          return user if ROLE_RANK.fetch(user.role) >= ROLE_RANK.fetch(role)

          replacement = User.new(
            id: user.id,
            role: role,
            status: user.status,
            created_at: user.created_at,
            updated_at: current_time,
            version: user.version + 1
          )
          store.replace_user(replacement, expected_version: user.version)
        end

        def normalize_provider(value)
          provider = value.to_s
          unless PROVIDER_PATTERN.match?(provider)
            raise ArgumentError, "provider must be a lowercase identifier"
          end

          provider.freeze
        end

        def normalize_provider_user_id(value)
          identifier = value.to_s
          raise ArgumentError, "provider_user_id must not be empty" if identifier.empty?
          raise ArgumentError, "provider_user_id is too long" if identifier.bytesize > 256

          identifier.freeze
        end

        def normalize_provider_data_key(value)
          key = value.to_s
          unless PROVIDER_DATA_KEY_PATTERN.match?(key)
            raise ArgumentError, "provider_data_key must be an identifier"
          end

          key.freeze
        end

        def normalize_provider_data_value(value)
          item = value.to_s
          raise ArgumentError, "provider_data_value must not be empty" if item.empty?
          raise ArgumentError, "provider_data_value is too long" if item.bytesize > 256

          item.freeze
        end

        def normalize_role(value)
          role = value.to_s
          unless AUTHENTICATABLE_ROLES.include?(role)
            raise ArgumentError, "authentication role is invalid"
          end

          role.freeze
        end

        def new_id
          Core::RecordSupport.identifier(@id_generator.call, field: "generated id")
        end

        def current_time
          value = @clock.call
          raise ArgumentError, "clock must return a Time" unless value.is_a?(Time)

          value.getutc
        end
      end
    end
  end
end
