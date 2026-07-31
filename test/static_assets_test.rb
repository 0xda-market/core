# frozen_string_literal: true

require_relative "test_helper"
require "rack/mock"
require "tmpdir"
require "zero_x_da/market/transport/static_assets"

class StaticAssetsTest < Minitest::Test
  def test_serves_the_index_and_nested_assets_with_cache_headers
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "index.html"), "<h1>market</h1>")
      File.write(File.join(directory, "app.js"), "export const ready = true;\n")
      client = Rack::MockRequest.new(
        ZeroXDA::Market::Transport::StaticAssets.new(root: directory, index: "index.html")
      )

      index = client.get("/")
      asset = client.get("/app.js")

      assert_equal 200, index.status
      assert_equal "<h1>market</h1>", index.body
      assert_equal 200, asset.status
      assert_equal "export const ready = true;\n", asset.body
      assert_includes asset["cache-control"], "max-age=300"
    end
  end

  def test_rejects_mutating_methods
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "index.html"), "ok")
      client = Rack::MockRequest.new(
        ZeroXDA::Market::Transport::StaticAssets.new(root: directory, index: "index.html")
      )

      response = client.post("/")

      assert_equal 405, response.status
      assert_equal "method not allowed\n", response.body
      assert_equal response.body.bytesize.to_s, response["content-length"]
    end
  end
end
