# frozen_string_literal: true
# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT

require "json"
require "sequel"

module ZeroXDA
  module Market
    module Identity
      class BrowserSessionStore
        def initialize(database:)
          @db = database.connection
          @rows = @db[Sequel.qualify(:market, :nilx_browser_sessions)]
        end

        def put(digest, kind, context, expires_at)
          @db.transaction do
            @rows.where(Sequel[:expires_at] < Time.now.to_i).delete
            @rows.insert(digest: digest, kind: kind, context: Sequel.pg_jsonb(context), expires_at: expires_at)
          end
        end

        def consume(digest, kind, now)
          # DELETE RETURNING is atomic across every API worker and instance.
          row = @rows.where(digest: digest, kind: kind).where { expires_at > now }.returning.delete.first
          row && row.fetch(:context).to_h
        end

        def read(digest, kind, now)
          row = @rows.where(digest: digest, kind: kind).where { expires_at > now }.first
          row && row.fetch(:context).to_h
        end
      end
    end
  end
end
