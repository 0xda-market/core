# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "zero_x_da/market/adapters/issuer_directory_http"

class IssuerDirectoryHTTPTest < Minitest::Test
  Directory = ZeroXDA::Market::Adapters::IssuerDirectoryHTTP
  Core = ZeroXDA::Market::Core
  ENDPOINT = "https://issuer.example/api/v1/partner/provider-lookup"

  def directory(status, body, calls = [])
    Directory.new(endpoint: ENDPOINT, token: "directory-token", providers: %w[telegram], requester: lambda { |uri, token, json|
      calls << [uri.to_s, token, JSON.parse(json)]
      Directory::Response.new(status: status, body: body)
    })
  end

  def test_a_linked_account_answers_its_public_handle
    calls = []
    found = directory(200, '{"state":"linked","pub_dress":"zero"}', calls).lookup(provider: "telegram",
                                                                                   provider_user_id: 42)
    assert_equal "zero", found
    assert_equal [[ENDPOINT, "directory-token", { "provider" => "telegram", "subject" => "42" }]], calls
  end

  def test_an_unbound_account_answers_nil
    assert_nil directory(200, '{"state":"sign_in_required","provider":"telegram"}')
      .lookup(provider: "telegram", provider_user_id: "7")
  end

  def test_an_answer_the_issuer_could_not_give_is_unavailable_not_unlinked
    [
      [503, '{"error":"unavailable"}'],
      [401, '{"error":"unauthorized"}'],
      [200, "not json"],
      [200, '{"state":"maybe"}'],
      [200, '{"state":"linked"}'],
      [200, '{"state":"linked","pub_dress":""}'],
      [200, "[]"],
      [200, "x" * (Directory::MAX_RESPONSE_BYTES + 1)]
    ].each do |status, body|
      error = assert_raises(Core::ProviderFailure, body[0, 40]) do
        directory(status, body).lookup(provider: "telegram", provider_user_id: "7")
      end
      assert_equal "issuer_unavailable", error.code
      assert error.retryable
    end
  end

  def test_only_https_endpoints_and_a_token_are_accepted
    assert_raises(ArgumentError) do
      Directory.new(endpoint: "http://issuer.example/lookup", token: "t", providers: %w[telegram])
    end
    assert_raises(ArgumentError) { Directory.new(endpoint: ENDPOINT, token: "", providers: %w[telegram]) }
    assert_raises(ArgumentError) { Directory.new(endpoint: ENDPOINT, token: "t", providers: []) }
    assert_raises(ArgumentError) do
      Directory.new(endpoint: ENDPOINT, token: "t", providers: %w[telegram], timeout_seconds: 0)
    end
  end

  def test_only_providers_the_issuer_binds_are_asked
    subject = directory(200, "{}")
    assert subject.supports?("telegram")
    refute subject.supports?("channel.example")
  end
end
