# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "rack/mock"
require "zero_x_da/market/identity/memory_store"
require "zero_x_da/market/identity/service"
require "zero_x_da/market/transport/channel_customer_assertion"

class ChannelCustomerAssertionTest < Minitest::Test
  Assertion = ZeroXDA::Market::Transport::ChannelCustomerAssertion
  SECRET = "s" * 32

  def setup
    @clock = MutableClock.new
    @users = ZeroXDA::Market::Identity::MemoryStore.new
    identities = ZeroXDA::Market::Identity::Service.new(store: @users, clock: @clock, id_generator: SequenceIDs.new)
    @customer = identities.authenticate(provider: "channel.example", provider_user_id: "100").user
    @other = identities.authenticate(provider: "channel.example", provider_user_id: "200").user
    @app = Assertion.new(
      ->(env) { [200, {}, [JSON.generate("customer" => env[Assertion::CONTEXT])]] },
      secret: SECRET, users: @users, providers: %w[channel.example], clock: @clock
    )
  end

  def test_a_fresh_signed_assertion_for_the_users_own_account_sets_the_customer
    assert_equal @customer.id, customer_for(sign)
  end

  def test_anything_else_leaves_the_customer_unset
    now = @clock.call
    forged = sign(secret: "x" * 32)
    tampered = sign.sub(/\.([^.]+)\./) { ".#{Assertion.encode(JSON.generate("user_id" => @other.id))}." }
    [
      nil,
      "",
      forged,
      tampered,
      sign.sub("v1.", "v2."),
      sign(user_id: @other.id),                  # another user's channel account
      sign(provider_user_id: "999"),             # an account the market does not know
      sign(provider: "other.example"),                 # a provider this deployment does not accept
      sign(now: now - 61),                       # expired
      sign(now: now + 31),                       # issued in the future
      sign(lifetime: Assertion::MAX_LIFETIME + 1),
      "#{sign}#{"a" * 1024}"
    ].each_with_index do |header, index|
      assert_nil customer_for(header), "case #{index}"
    end
  end

  def test_a_blocked_user_is_never_a_verified_customer
    blocked = ZeroXDA::Market::Identity::User.new(id: @customer.id, role: @customer.role, status: "blocked",
                                                    created_at: @customer.created_at, version: @customer.version + 1)
    @users.replace_user(blocked, expected_version: @customer.version)
    assert_nil customer_for(sign)
  end

  def test_a_header_or_upstream_value_can_never_set_the_context_directly
    response = Rack::MockRequest.new(@app).get(
      "/", "HTTP_ZERO_X_DA_MARKET_VERIFIED_CUSTOMER_ID" => @customer.id,
           Assertion::CONTEXT => @customer.id
    )
    assert_nil JSON.parse(response.body).fetch("customer")
  end

  def test_refuses_a_weak_secret_or_no_providers
    assert_raises(ArgumentError) { Assertion.new(->(_) {}, secret: "short", users: @users, providers: %w[channel.example]) }
    assert_raises(ArgumentError) { Assertion.new(->(_) {}, secret: SECRET, users: @users, providers: []) }
  end

  private

  def sign(secret: SECRET, user_id: @customer.id, provider: "channel.example", provider_user_id: "100", now: @clock.call,
           lifetime: 60)
    Assertion.sign(secret: secret, user_id: user_id, provider: provider, provider_user_id: provider_user_id,
                   now: now, lifetime: lifetime)
  end

  def customer_for(header)
    headers = header ? { "HTTP_X_MARKET_CUSTOMER_ASSERTION" => header } : {}
    JSON.parse(Rack::MockRequest.new(@app).get("/", headers).body).fetch("customer")
  end
end
