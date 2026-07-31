# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "rack/mock"
require "uri"
require "zero_x_da/market/identity/admin_service"
require "zero_x_da/market/identity/memory_store"
require "zero_x_da/market/identity/service"
require "zero_x_da/market/transport/json_api"

class ExternalIdentityLookupAPITest < Minitest::Test
  include KernelFixture

  def setup
    @clock = MutableClock.new
    provider = TestProvider.new(clock: @clock)
    @kernel, = build_kernel(provider: provider, clock: @clock)
    @store = ZeroXDA::Market::Identity::MemoryStore.new
    @identity_service = ZeroXDA::Market::Identity::Service.new(
      store: @store,
      clock: @clock,
      id_generator: SequenceIDs.new
    )
    @actor = @identity_service.authenticate(
      provider: "telegram",
      provider_user_id: 77,
      provider_data: { username: "owner", chat_id: "770" }
    ).user
    @target = @identity_service.authenticate(
      provider: "telegram",
      provider_user_id: 78,
      provider_data: { username: "Target_User", chat_id: "780" }
    ).user
    @admin_service = ZeroXDA::Market::Identity::AdminService.new(
      store: @store,
      clock: @clock
    )
    @admin_service.bootstrap(user_id: @actor.id)
    @client = Rack::MockRequest.new(
      ZeroXDA::Market::Transport::JSONAPI.new(
        kernel: @kernel,
        token: "client-secret",
        identity_service: @identity_service,
        admin_service: @admin_service
      )
    )
  end

  def test_admin_resolves_a_user_by_provider_user_id
    response = authorized_get(
      actor_user_id: @actor.id,
      provider: "telegram",
      provider_user_id: "78"
    )

    assert_equal 200, response.status, response.body
    user = JSON.parse(response.body).fetch("data")
    assert_equal @target.id, user.fetch("id")
    assert_equal "78", user.dig("attributes", "identities", 0, "provider_user_id")
  end

  def test_admin_resolves_provider_data_case_insensitively
    response = authorized_get(
      actor_user_id: @actor.id,
      provider: "telegram",
      provider_data_key: "username",
      provider_data_value: "target_user",
      case_insensitive: "true"
    )

    assert_equal 200, response.status, response.body
    assert_equal @target.id, JSON.parse(response.body).dig("data", "id")
  end

  def test_lookup_requires_api_and_admin_authorization
    path = lookup_path(
      actor_user_id: @target.id,
      provider: "telegram",
      provider_user_id: "78"
    )

    assert_equal 401, @client.get(path).status

    forbidden = @client.get(path, "HTTP_AUTHORIZATION" => "Bearer client-secret")
    assert_equal 403, forbidden.status
    assert_equal "forbidden", JSON.parse(forbidden.body).dig("errors", 0, "code")
  end

  def test_lookup_returns_not_found_without_listing_active_users
    response = authorized_get(
      actor_user_id: @actor.id,
      provider: "telegram",
      provider_user_id: "404"
    )

    assert_equal 404, response.status
    assert_equal "not_found", JSON.parse(response.body).dig("errors", 0, "code")
  end

  private

  def authorized_get(parameters)
    @client.get(
      lookup_path(parameters),
      "HTTP_AUTHORIZATION" => "Bearer client-secret"
    )
  end

  def lookup_path(parameters)
    "/v1/admin/users/by-external-identity?#{URI.encode_www_form(parameters)}"
  end
end
