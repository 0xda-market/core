# frozen_string_literal: true
# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT

require_relative "test_helper"
require "rack/mock"
require "json"
require "zero_x_da/market/points/memory_store"
require "zero_x_da/market/points/service"
require "zero_x_da/market/transport/nilx_browser_api"

class MarketPointsTest < Minitest::Test
  P = ZeroXDA::Market::Points

  class Sessions
    def initialize
      @rows = {}
    end

    def put(key, kind, value, expiry)
      @rows[[key, kind]] = [value, expiry]
    end

    def read(key, kind, now)
      row = @rows[[key, kind]]
      row && row.last > now ? row.first : nil
    end

    def consume(key, kind, now)
      row = read(key, kind, now)
      @rows.delete([key, kind])
      row
    end
  end

  def setup
    store = P::MemoryStore.new(
      points: [
        P::Point.new(address: "zoloti", owner_pub_dress: "0xda-market", place: "zoloti-vorota"),
        P::Point.new(address: "batkivshchyna", owner_pub_dress: "0xda-market", place: "batkivshchyna")
      ],
      aliases: { "zoloti-vorota" => "zoloti", "золоті" => "zoloti" }
    )
    @points = P::Service.new(store: store)
    identity = Object.new
    identity.define_singleton_method(:authenticate) { |**| Struct.new(:user).new(Struct.new(:id).new("market-person")) }
    @client = Rack::MockRequest.new(ZeroXDA::Market::Transport::NilxBrowserAPI.new(
      store: Sessions.new, identity_service: identity, token: "a" * 32, clock: -> { 1000 }, points: @points
    ))
  end

  def test_an_address_is_canonical_and_older_links_resolve_to_it
    zoloti = @points.resolve("zoloti")
    assert_equal ["zoloti", "0xda-market-zoloti-vorota", true],
                 [zoloti.point.address, zoloti.point.station_pub_dress, zoloti.canonical]
    %w[zoloti-vorota золоті ZOLOTI].each do |older|
      resolution = @points.resolve(older)
      assert_equal ["zoloti", false], [resolution.point.address, resolution.canonical], older
    end
    ["", "zoloti/x", "nowhere", "a" * 65, "\xFF".b.force_encoding(Encoding::UTF_8)].each do |unknown|
      assert_nil @points.resolve(unknown), unknown.inspect
    end
  end

  def test_the_handoff_place_becomes_the_address
    assert_equal "zoloti", @points.address_for(owner_pub_dress: "0xda-market", point: "zoloti-vorota")
    assert_equal "zoloti", @points.address_for(owner_pub_dress: "0xda-market", point: "золоті")
    assert_equal "batkivshchyna", @points.address_for(owner_pub_dress: "0xda-market", point: "batkivshchyna")
    assert_nil @points.address_for(owner_pub_dress: "other-market", point: "nowhere")
  end

  def test_exchange_redirects_to_the_canonical_address
    issued = @client.post("/handoffs", "HTTP_AUTHORIZATION" => "Bearer #{'a' * 32}", "CONTENT_TYPE" => "application/json",
      input: JSON.generate(subject: "b" * 64, point: "zoloti-vorota", seeds: "0", avaia: { longitude: 30.5, latitude: 50.4 }))
    assert_equal 201, issued.status
    exchanged = @client.post("/exchange", "HTTP_ORIGIN" => "https://nilx.one",
      "CONTENT_TYPE" => "application/x-www-form-urlencoded", input: "code=#{JSON.parse(issued.body).fetch('code')}")
    assert_equal 303, exchanged.status
    assert_equal "https://0xda-market.nilx.one/zoloti", exchanged["location"]
    session = @client.get("/session", "HTTP_COOKIE" => exchanged["set-cookie"].split(";").first)
    assert_equal "zoloti", JSON.parse(session.body).fetch("address")
  end

  def test_unknown_points_keep_the_previous_redirect
    issued = @client.post("/handoffs", "HTTP_AUTHORIZATION" => "Bearer #{'a' * 32}", "CONTENT_TYPE" => "application/json",
      input: JSON.generate(subject: "b" * 64, point: "nowhere", seeds: "0", avaia: { longitude: 30.5, latitude: 50.4 }))
    exchanged = @client.post("/exchange", "HTTP_ORIGIN" => "https://nilx.one",
      "CONTENT_TYPE" => "application/x-www-form-urlencoded", input: "code=#{JSON.parse(issued.body).fetch('code')}")
    assert_equal "https://0xda-market.nilx.one/nowhere", exchanged["location"]
  end

  def test_public_point_lookup
    list = JSON.parse(@client.get("/points").body).fetch("points")
    assert_includes list, { "address" => "zoloti", "station_pub_dress" => "0xda-market-zoloti-vorota", "path" => "/zoloti" }
    canonical = JSON.parse(@client.get("/points/zoloti").body).fetch("point")
    assert canonical.fetch("canonical")
    older = @client.get("/points/#{Rack::Utils.escape_path('золоті')}")
    assert_equal 200, older.status
    assert_equal({ "address" => "zoloti", "station_pub_dress" => "0xda-market-zoloti-vorota", "path" => "/zoloti",
                   "canonical" => false }, JSON.parse(older.body).fetch("point"))
    assert_equal 404, @client.get("/points/nowhere").status
    assert_equal 404, @client.get("/points/zoloti/extra").status
    assert_equal 404, @client.post("/points").status
  end

  def test_point_lookup_is_absent_without_a_registry
    client = Rack::MockRequest.new(ZeroXDA::Market::Transport::NilxBrowserAPI.new(
      store: Sessions.new, identity_service: Object.new, token: "a" * 32
    ))
    assert_equal 404, client.get("/points").status
  end

  def test_points_reject_invalid_segments
    assert_raises(ArgumentError) { P::Point.new(address: "Zoloti", owner_pub_dress: "0xda-market", place: "x") }
    assert_raises(ArgumentError) { P::Point.new(address: "z" * 49, owner_pub_dress: "0xda-market", place: "x") }
    assert_raises(ArgumentError) { P::MemoryStore.new(aliases: { "old" => "missing" }) }
  end
end
