# frozen_string_literal: true

require_relative "test_helper"
require "rack/mock"

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

  def test_customer_issuer_order_routes_are_off_unless_enabled_and_never_in_production
    base = { "PUBLIC_API_TOKEN" => "client-secret", "MANUAL_PROVIDER_TOKEN" => nil, "DATABASE_URL" => nil }

    with_environment(base.merge("DEPLOY_ENV" => "development", "ENABLE_ISSUER_ORDER_ROUTES" => nil)) do
      app = Rack::Builder.parse_file(File.expand_path("../config.ru", __dir__))
      assert_equal "route_not_found", issuer_account_error(app)
      created = post_json(app, "/v1/issuer-orders", {}, authorization: "Bearer client-secret")
      assert_equal "route_not_found", JSON.parse(created.body).dig("errors", 0, "code")
    end

    with_environment(base.merge("DEPLOY_ENV" => "development", "ENABLE_ISSUER_ORDER_ROUTES" => "1")) do
      app = Rack::Builder.parse_file(File.expand_path("../config.ru", __dir__))
      assert_equal "not_found", issuer_account_error(app)
    end

    with_environment(base.merge("DEPLOY_ENV" => "production", "DATABASE_URL" => "postgresql://unused",
                                "MANUAL_PROVIDER_TOKEN" => "operator-secret", "ENABLE_ISSUER_ORDER_ROUTES" => "1")) do
      error = assert_raises(RuntimeError) { Rack::Builder.parse_file(File.expand_path("../config.ru", __dir__)) }
      assert_includes error.message, "issuer order routes"
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
  # route_not_found when the routes are off, not_found for the user otherwise.
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
