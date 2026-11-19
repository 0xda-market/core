# frozen_string_literal: true

require_relative "test_helper"
require "rack/mock"
require "minitest/mock"

class RuntimeTest < Minitest::Test
  def test_starts_in_health_only_mode_without_an_operator_token
    with_environment(
      "DEPLOY_ENV" => nil,
      "PUBLIC_API_TOKEN" => nil,
      "MANUAL_PROVIDER_TOKEN" => nil,
      "DATABASE_URL" => nil
    ) do
      app = Rack::Builder.parse_file(File.expand_path("../config.ru", __dir__))

      health = Rack::MockRequest.new(app).get("/health")
      assert_equal 200, health.status
      assert_match(/\A\d{4}-\d{2}-\d{2}T/, JSON.parse(health.body).fetch("server_time"))

      intent = post_json(
        app,
        "/v1/intents",
        { capability: "manual.fulfillment", payload: {} }
      )
      assert_equal 422, intent.status
    end
  end

  def test_mounts_manual_provider_when_an_operator_token_is_configured
    with_environment(
      "DEPLOY_ENV" => "development",
      "PUBLIC_API_TOKEN" => "client-secret",
      "MANUAL_PROVIDER_TOKEN" => "operator-secret",
      "DATABASE_URL" => nil
    ) do
      app = Rack::Builder.parse_file(File.expand_path("../config.ru", __dir__))

      intent = post_json(
        app,
        "/v1/intents",
        { capability: "manual.fulfillment", payload: { action: "deliver" } },
        authorization: "Bearer client-secret"
      )
      assert_equal 201, intent.status

      authentication = post_json(
        app,
        "/v1/auth/external",
        {
          provider: "telegram",
          provider_user_id: 77,
          provider_data: { chat_id: "77", username: "zero" }
        },
        authorization: "Bearer client-secret"
      )
      assert_equal 201, authentication.status
      assert_equal "client", JSON.parse(authentication.body).dig("data", "attributes", "role")

      public_unauthorized = post_json(
        app,
        "/v1/intents",
        { capability: "manual.fulfillment", payload: {} }
      )
      assert_equal 401, public_unauthorized.status

      unauthorized = Rack::MockRequest.new(app).get("/operator/v1/tasks")
      assert_equal 401, unauthorized.status
    end
  end

  def test_does_not_mount_provider_specific_webhooks
    with_environment(
      "DEPLOY_ENV" => "development",
      "PUBLIC_API_TOKEN" => "client-secret",
      "MANUAL_PROVIDER_TOKEN" => "operator-secret",
      "DATABASE_URL" => nil
    ) do
      app = Rack::Builder.parse_file(File.expand_path("../config.ru", __dir__))
      client = Rack::MockRequest.new(app)
      headers = { "HTTP_AUTHORIZATION" => "Bearer client-secret" }

      assert_equal 404, client.get("/telegram/client", headers).status
      assert_equal 404, client.get("/telegram/broker", headers).status
    end
  end

  def test_rejects_production_boot_with_missing_secrets
    with_environment(
      "DEPLOY_ENV" => "production",
      "PUBLIC_API_TOKEN" => nil,
      "MANUAL_PROVIDER_TOKEN" => nil,
      "DATABASE_URL" => nil
    ) do
      error = assert_raises(RuntimeError) do
        Rack::Builder.parse_file(File.expand_path("../config.ru", __dir__))
      end

      assert_includes error.message, "PUBLIC_API_TOKEN"
      assert_includes error.message, "MANUAL_PROVIDER_TOKEN"
      assert_includes error.message, "DATABASE_URL"
    end
  end

  def test_mounts_the_issuer_api_only_with_its_own_token_and_issuer
    with_environment(
      "DEPLOY_ENV" => "development", "PUBLIC_API_TOKEN" => "client-secret", "MANUAL_PROVIDER_TOKEN" => nil,
      "DATABASE_URL" => nil, "ISSUER_API_TOKEN" => "issuer-secret", "ISSUER_API_ISSUER" => "issuer.example"
    ) do
      client = Rack::MockRequest.new(Rack::Builder.parse_file(File.expand_path("../config.ru", __dir__)))

      assert_equal 401, client.get("/issuer/v1/orders").status
      assert_equal 401, client.get("/issuer/v1/orders", "HTTP_AUTHORIZATION" => "Bearer client-secret").status
      queue = client.get("/issuer/v1/orders", "HTTP_AUTHORIZATION" => "Bearer issuer-secret")
      assert_equal 200, queue.status
      assert_equal "issuer.example", JSON.parse(queue.body).dig("meta", "issuer")
    end

    with_environment(
      "DEPLOY_ENV" => "development", "PUBLIC_API_TOKEN" => "client-secret", "MANUAL_PROVIDER_TOKEN" => nil,
      "DATABASE_URL" => nil, "ISSUER_API_TOKEN" => nil, "ISSUER_API_ISSUER" => nil
    ) do
      client = Rack::MockRequest.new(Rack::Builder.parse_file(File.expand_path("../config.ru", __dir__)))
      assert_equal 401, client.get("/issuer/v1/orders", "HTTP_AUTHORIZATION" => "Bearer issuer-secret").status
    end
  end

  def test_customer_issuer_order_routes_require_configured_adapter_and_need_a_strong_setup_in_production
    base = { "PUBLIC_API_TOKEN" => "client-secret", "MANUAL_PROVIDER_TOKEN" => nil, "DATABASE_URL" => nil }

    with_environment(base.merge("DEPLOY_ENV" => "development", "CHANNEL_ASSERTION_SECRET" => nil,
                                "CHANNEL_ASSERTION_PROVIDERS" => "channel.example")) do
      app = Rack::Builder.parse_file(File.expand_path("../config.ru", __dir__))
      assert_equal "route_not_found", issuer_account_error(app)
      created = post_json(app, "/v1/issuer-orders", {}, authorization: "Bearer client-secret")
      assert_equal "route_not_found", JSON.parse(created.body).dig("errors", 0, "code")
    end

    with_environment(base.merge("DEPLOY_ENV" => "development", "CHANNEL_ASSERTION_SECRET" => "c" * 32,
                                "CHANNEL_ASSERTION_PROVIDERS" => nil)) do
      error = assert_raises(RuntimeError) { Rack::Builder.parse_file(File.expand_path("../config.ru", __dir__)) }
      assert_includes error.message, "CHANNEL_ASSERTION_SECRET"
    end

    with_environment(base.merge("DEPLOY_ENV" => "development", "CHANNEL_ASSERTION_SECRET" => "c" * 32,
                                "CHANNEL_ASSERTION_PROVIDERS" => "channel.example")) do
      app = Rack::Builder.parse_file(File.expand_path("../config.ru", __dir__))
      assert_equal "unauthorized", issuer_account_error(app)
    end

    production = base.merge("DEPLOY_ENV" => "production",
                            "DATABASE_URL" => "postgres://market:secret@market-postgres-production:1927/market",
                            "MANUAL_PROVIDER_TOKEN" => "operator-secret",
                            "CHANNEL_ASSERTION_PROVIDERS" => "channel.example",
                            "ISSUER_DIRECTORY_URL" => "https://directory.example/lookup",
                            "ISSUER_DIRECTORY_TOKEN" => "d" * 32, "ISSUER_DIRECTORY_PROVIDERS" => "channel.example")
    boot = -> { Rack::Builder.parse_file(File.expand_path("../config.ru", __dir__)) }

    # A weak secret or missing issuer directory prevents the production
    # channel adapter from starting.
    with_environment(production.merge("CHANNEL_ASSERTION_SECRET" => "c" * 31)) do
      assert_includes assert_raises(RuntimeError, &boot).message, "CHANNEL_ASSERTION_SECRET of at least 32 bytes"
    end
    # A complete production setup gets past this guard and on to the database.
    # Booting it for real needs PostgreSQL, so stop at the adapter with a marker.
    reached_database = Class.new(StandardError)
    ZeroXDA::Market::Adapters::PostgresDatabase.stub(:new, ->(**) { raise reached_database }) do
      with_environment(production.merge("CHANNEL_ASSERTION_SECRET" => "c" * 32)) do
        assert_raises(reached_database, &boot)
      end
    end
    %w[ISSUER_DIRECTORY_URL ISSUER_DIRECTORY_TOKEN ISSUER_DIRECTORY_PROVIDERS].each do |name|
      with_environment(production.merge("CHANNEL_ASSERTION_SECRET" => "c" * 32, name => nil)) do
        assert_raises(RuntimeError, &boot)
      end
    end
  end

  def test_rejects_a_half_configured_issuer_api
    with_environment(
      "DEPLOY_ENV" => "development", "PUBLIC_API_TOKEN" => "client-secret", "MANUAL_PROVIDER_TOKEN" => nil,
      "DATABASE_URL" => nil, "ISSUER_API_TOKEN" => "issuer-secret", "ISSUER_API_ISSUER" => nil
    ) do
      error = assert_raises(RuntimeError) { Rack::Builder.parse_file(File.expand_path("../config.ru", __dir__)) }
      assert_includes error.message, "ISSUER_API_ISSUER"
    end
  end

  def test_rejects_a_runtime_without_a_positive_marketplace_margin
    with_environment(
      "DEPLOY_ENV" => "development",
      "PUBLIC_API_TOKEN" => "client-secret",
      "MANUAL_PROVIDER_TOKEN" => "operator-secret",
      "DATABASE_URL" => nil,
      "MARKETPLACE_MIN_MARGIN_BPS" => "0"
    ) do
      assert_raises(ArgumentError) do
        Rack::Builder.parse_file(File.expand_path("../config.ru", __dir__))
      end
    end
  end

  private

  def with_environment(changes)
    previous = changes.to_h { |name, _value| [name, ENV[name]] }
    changes.each do |name, value|
      if value
        ENV[name] = value
      else
        ENV.delete(name)
      end
    end
    yield
  ensure
    previous.each do |name, value|
      if value
        ENV[name] = value
      else
        ENV.delete(name)
      end
    end
  end

  # The error code for an account-status request by an unknown user:
  # route_not_found when disabled, unauthorized without a verified customer otherwise.
  def issuer_account_error(app)
    response = Rack::MockRequest.new(app).get("/v1/issuer-accounts/issuer.example?actor_user_id=unknown",
                                              "HTTP_AUTHORIZATION" => "Bearer client-secret")
    JSON.parse(response.body).dig("errors", 0, "code")
  end

  def post_json(app, path, body, authorization: nil)
    headers = { "CONTENT_TYPE" => "application/json" }
    headers["HTTP_AUTHORIZATION"] = authorization if authorization
    headers[:input] = JSON.generate(body)
    Rack::MockRequest.new(app).post(path, headers)
  end
end
