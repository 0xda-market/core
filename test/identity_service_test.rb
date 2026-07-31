# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/identity/memory_store"
require "zero_x_da/market/identity/service"

class IdentityServiceTest < Minitest::Test
  def setup
    @clock = MutableClock.new
    @store = ZeroXDA::Market::Identity::MemoryStore.new
    @service = ZeroXDA::Market::Identity::Service.new(
      store: @store,
      clock: @clock,
      id_generator: SequenceIDs.new
    )
  end

  def test_creates_an_internal_user_and_external_identity
    authentication = @service.authenticate(
      provider: "telegram",
      provider_user_id: 77,
      provider_data: { chat_id: "77", username: "zero" }
    )

    assert authentication.created
    assert_equal "id-1", authentication.user.id
    assert_equal "client", authentication.user.role
    assert_equal "telegram", authentication.identity.provider
    assert_equal "77", authentication.identity.provider_user_id
    assert_equal "zero", authentication.identity.provider_data.fetch("username")
  end

  def test_supports_another_provider_without_code_changes
    authentication = @service.authenticate(
      provider: "github",
      provider_user_id: "75973992",
      provider_data: { login: "0x0sky" }
    )

    assert_equal "github", authentication.identity.provider
    assert_equal "75973992", authentication.identity.provider_user_id
    assert_equal "0x0sky", authentication.identity.provider_data.fetch("login")
  end

  def test_reuses_the_user_and_updates_provider_data
    first = @service.authenticate(
      provider: "telegram",
      provider_user_id: "77",
      provider_data: { chat_id: "77", username: "old" }
    )
    @clock.advance(60)

    second = @service.authenticate(
      provider: "telegram",
      provider_user_id: 77,
      provider_data: { chat_id: "770", username: "new", language_code: "uk" }
    )

    refute second.created
    assert_equal first.user.id, second.user.id
    assert_equal first.identity.id, second.identity.id
    assert_equal 1, second.identity.version
    assert_equal "770", second.identity.provider_data.fetch("chat_id")
    assert_operator second.identity.last_authenticated_at, :>, first.identity.last_authenticated_at
  end

  def test_trusted_broker_authentication_promotes_without_downgrade
    @service.authenticate(provider: "telegram", provider_user_id: 77)

    broker = @service.authenticate(
      provider: "telegram",
      provider_user_id: 77,
      role: "broker"
    )
    client = @service.authenticate(provider: "telegram", provider_user_id: 77)

    assert_equal "broker", broker.user.role
    assert_equal "broker", client.user.role
  end

  def test_authentication_cannot_assign_admin_role
    error = assert_raises(ArgumentError) do
      @service.authenticate(provider: "telegram", provider_user_id: 77, role: "admin")
    end

    assert_includes error.message, "role is invalid"
  end

  def test_lists_users_with_all_external_identities
    authentication = @service.authenticate(provider: "telegram", provider_user_id: 77)
    github_identity = ZeroXDA::Market::Identity::ExternalIdentity.new(
      id: "identity-github",
      user_id: authentication.user.id,
      provider: "github",
      provider_user_id: "75973992",
      provider_data: { login: "0x0sky" },
      created_at: @clock.call
    )
    @store.insert_identity(github_identity)

    profile = @service.active_users.fetch(0)

    assert_equal authentication.user.id, profile.user.id
    assert_equal %w[github telegram], profile.identities.map(&:provider)
  end

  def test_finds_a_profile_by_provider_user_id_without_listing_users
    authentication = @service.authenticate(
      provider: "telegram",
      provider_user_id: 77,
      provider_data: { username: "zero" }
    )

    profile = @service.find_profile_by_external_identity(
      provider: "telegram",
      provider_user_id: "77"
    )

    assert_equal authentication.user.id, profile.user.id
    assert_equal ["77"], profile.identities.map(&:provider_user_id)
  end

  def test_finds_a_profile_by_case_insensitive_provider_data
    authentication = @service.authenticate(
      provider: "telegram",
      provider_user_id: 77,
      provider_data: { username: "Target_User" }
    )

    profile = @service.find_profile_by_external_identity(
      provider: "telegram",
      provider_data_key: "username",
      provider_data_value: "target_user",
      case_insensitive: true
    )

    assert_equal authentication.user.id, profile.user.id
  end

  def test_provider_data_lookup_fails_closed_when_multiple_identities_match
    @service.authenticate(
      provider: "telegram",
      provider_user_id: 77,
      provider_data: { username: "shared_name" }
    )
    @clock.advance(1)
    @service.authenticate(
      provider: "telegram",
      provider_user_id: 78,
      provider_data: { username: "Shared_Name" }
    )

    error = assert_raises(ZeroXDA::Market::Core::Conflict) do
      @service.find_profile_by_external_identity(
        provider: "telegram",
        provider_data_key: "username",
        provider_data_value: "shared_name",
        case_insensitive: true
      )
    end

    assert_equal "ambiguous_external_identity", error.code
    assert_equal 2, error.details.fetch("matches")
  end

  def test_external_identity_lookup_requires_exactly_one_selector
    error = assert_raises(ArgumentError) do
      @service.find_profile_by_external_identity(provider: "telegram")
    end
    assert_includes error.message, "exactly one"

    error = assert_raises(ArgumentError) do
      @service.find_profile_by_external_identity(
        provider: "telegram",
        provider_user_id: 77,
        provider_data_key: "username",
        provider_data_value: "zero"
      )
    end
    assert_includes error.message, "exactly one"
  end

  def test_external_identity_lookup_reports_not_found
    error = assert_raises(ZeroXDA::Market::Core::NotFound) do
      @service.find_profile_by_external_identity(
        provider: "telegram",
        provider_user_id: 404
      )
    end

    assert_equal "not_found", error.code
    assert_equal "external_identity", error.details.fetch("resource")
  end

  def test_rejects_invalid_provider_names
    error = assert_raises(ArgumentError) do
      @service.authenticate(provider: "Telegram API", provider_user_id: 77)
    end

    assert_includes error.message, "lowercase identifier"
  end
end
