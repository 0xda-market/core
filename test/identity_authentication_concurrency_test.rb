# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/identity/memory_store"
require "zero_x_da/market/identity/service"

class IdentityAuthenticationConcurrencyTest < Minitest::Test
  class OneShotConflictStore < ZeroXDA::Market::Identity::MemoryStore
    attr_reader :replace_attempts

    def initialize
      super
      @replace_attempts = 0
      @fail_next_identity_replace = false
    end

    def fail_next_identity_replace!
      @fail_next_identity_replace = true
    end

    def replace_identity(identity, expected_version:)
      @replace_attempts += 1
      if @fail_next_identity_replace
        @fail_next_identity_replace = false
        raise ZeroXDA::Market::Core::ConcurrencyConflict.new("user_identity", identity.id)
      end

      super
    end
  end

  def test_retries_an_idempotent_external_authentication_after_identity_conflict
    clock = MutableClock.new
    store = OneShotConflictStore.new
    service = ZeroXDA::Market::Identity::Service.new(
      store: store,
      clock: clock,
      id_generator: SequenceIDs.new
    )
    first = service.authenticate(
      provider: "telegram",
      provider_user_id: 77,
      provider_data: { username: "old" }
    )
    store.fail_next_identity_replace!
    clock.advance(1)

    authentication = service.authenticate(
      provider: "telegram",
      provider_user_id: 77,
      provider_data: { username: "new", language_code: "uk" }
    )

    refute authentication.created
    assert_equal first.user.id, authentication.user.id
    assert_equal 1, authentication.identity.version
    assert_equal "new", authentication.identity.provider_data.fetch("username")
    assert_equal "uk", authentication.identity.provider_data.fetch("language_code")
    assert_equal 2, store.replace_attempts
  end
end
