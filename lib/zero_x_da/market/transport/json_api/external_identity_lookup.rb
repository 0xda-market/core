# frozen_string_literal: true

module ZeroXDA
  module Market
    module Transport
      class JSONAPI
        module ExternalIdentityLookup
          def external_identity_user(request)
            @admin_service.require_admin(user_id: request.params.fetch("actor_user_id"))
            profile = @identity_service.find_profile_by_external_identity(
              provider: request.params.fetch("provider"),
              provider_user_id: request.params["provider_user_id"],
              provider_data_key: request.params["provider_data_key"],
              provider_data_value: request.params["provider_data_value"],
              case_insensitive: requested_case_insensitive(request)
            )
            resource_response(200, present_user_profile(profile))
          end

          private

          def requested_case_insensitive(request)
            value = request.params["case_insensitive"]
            return false if value.nil? || value == "false"
            return true if value == "true"

            raise ArgumentError, "case_insensitive must be true or false"
          end
        end

        EndpointHandler.include(ExternalIdentityLookup)
      end
    end
  end
end
