# frozen_string_literal: true

require "rack"

module ZeroXDA
  module Market
    module Transport
      class StaticAssets
        CACHE_CONTROL = "public, max-age=300, stale-while-revalidate=3600"

        def initialize(root:, index:)
          @files = Rack::Files.new(File.expand_path(root))
          @index = index.to_s
        end

        def call(environment)
          request = Rack::Request.new(environment)
          return method_not_allowed unless request.get? || request.head?

          path = request.path_info
          path = "/#{@index}" if path.empty? || path == "/"
          status, headers, body = @files.call(environment.merge("PATH_INFO" => path))
          headers = headers.merge("cache-control" => CACHE_CONTROL) if status == 200
          [status, headers, body]
        end

        private

        def method_not_allowed
          [405, { "content-type" => "text/plain; charset=utf-8", "content-length" => "18" }, ["method not allowed\n"]]
        end
      end
    end
  end
end
