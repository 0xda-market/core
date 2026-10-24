# frozen_string_literal: true
# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
require "minitest/autorun"
require "rack/mock"
require_relative "../lib/zero_x_da/market/transport/nilx_browser_api"

class NilxBrowserAPITest < Minitest::Test
  class Store
    def initialize
      @rows = {}
      @lock = Mutex.new
    end
    def put(key, kind, context, expiry)
      @lock.synchronize { @rows[[key, kind]] = [context, expiry] }
    end
    def consume(key, kind, now)
      @lock.synchronize do
        row = @rows.delete([key, kind])
        row&.last.to_i > now ? row.first : nil
      end
    end
    def read(key, kind, now)
      row = @rows[[key, kind]]
      row&.last.to_i > now ? row.first : nil
    end
  end

  def setup
    @now = 1000
    @calls = []
    identity = Object.new
    calls = @calls
    identity.define_singleton_method(:authenticate) do |**input|
      calls << input
      Struct.new(:user).new(Struct.new(:id).new("market-person"))
    end
    @client = Rack::MockRequest.new(ZeroXDA::Market::Transport::NilxBrowserAPI.new(
      store: Store.new, identity_service: identity, token: "a" * 32, clock: -> { @now }
    ))
    @context = { subject: "b" * 64, point: "золоті", seeds: "400", avaia: { longitude: 30.5, latitude: 50.4 } }
  end

  def issue
    @client.post("/handoffs", "HTTP_AUTHORIZATION" => "Bearer #{'a' * 32}",
      "CONTENT_TYPE" => "application/json", input: JSON.generate(@context))
  end

  def exchange(code, origin = "https://nilx.one")
    @client.post("/exchange", "HTTP_ORIGIN" => origin,
      "CONTENT_TYPE" => "application/x-www-form-urlencoded", input: "code=#{code}")
  end

  def test_requires_service_authentication_and_trusted_browser_origin
    assert_equal 401, @client.post("/handoffs", input: JSON.generate(@context)).status
    code = JSON.parse(issue.body).fetch("code")
    assert_equal 403, exchange(code, "https://evil.example").status
    assert_empty @calls
    assert_equal 303, exchange(code).status
  end

  def test_single_use_exchange_and_private_session_projection
    issued = issue
    assert_equal 201, issued.status
    code = JSON.parse(issued.body).fetch("code")
    accepted = exchange(code)
    assert_equal 303, accepted.status
    assert_equal "https://0xda-market.nilx.one/#{Rack::Utils.escape_path("золоті")}", accepted["location"]
    assert_equal 401, exchange(code).status
    cookie = accepted["set-cookie"].split(";").first
    session = @client.get("/session", "HTTP_COOKIE" => cookie)
    view = JSON.parse(session.body)
    assert_equal "400", view["seeds"]
    assert_equal "client_display", view["seeds_authority"]
    refute view.key?("subject")
    refute view.key?("market_user_id")
    assert_equal [{ provider: "nilx", provider_user_id: "b" * 64 }], @calls
    @now += 1800
    assert_equal 401, @client.get("/session", "HTTP_COOKIE" => cookie).status
  end

  def test_other_selected_points_redirect_to_their_own_page
    @context[:point] = "batkivshchyna"
    code = JSON.parse(issue.body).fetch("code")
    accepted = exchange(code)
    assert_equal 303, accepted.status
    assert_equal "https://0xda-market.nilx.one/batkivshchyna", accepted["location"]
  end

  def test_expired_codes_and_invalid_context_are_rejected
    code = JSON.parse(issue.body).fetch("code")
    @now += 60
    assert_equal 401, exchange(code).status
    @context[:point] = "//evil.example"
    assert_equal 422, issue.status
    assert_empty @calls
  end
end
