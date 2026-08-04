# frozen_string_literal: true

require "json"

module ZeroXDA
  module Market
    module Transport
      class JSONAPI
        module Response
          JSON_HEADERS = {
            "content-type" => "application/json; charset=utf-8",
            "cache-control" => "no-store"
          }.freeze

          private

          def resource_response(status, resource)
            json_response(status, { "data" => resource })
          end

          def json_response(status, document)
            [status, JSON_HEADERS, [JSON.generate(document)]]
          end

          def post_status_response(response)
            http_status, headers, body = response
            payload = body.each_with_object(+"") { |chunk, buffer| buffer << chunk.to_s }
            body.close if body.respond_to?(:close)
            document = JSON.parse(payload)
            document["status"] ||= (200..299).cover?(http_status.to_i) ? "ok" : "error"
            [http_status, headers, [JSON.generate(document)]]
          end
        end
      end
    end
  end
end
