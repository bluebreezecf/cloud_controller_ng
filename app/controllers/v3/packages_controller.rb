require 'presenters/v3/package_presenter'
require 'presenters/v3/droplet_presenter'
require 'handlers/packages_handler'
require 'queries/package_delete_fetcher'
require 'queries/package_stage_fetcher'
require 'actions/package_stage_action'
require 'actions/package_delete'

module VCAP::CloudController
  class PackagesController < RestController::BaseController
    def self.dependencies
      [:packages_handler, :package_presenter, :droplet_presenter, :apps_handler, :stagers]
    end

    def inject_dependencies(dependencies)
      @packages_handler  = dependencies[:packages_handler]
      @package_presenter = dependencies[:package_presenter]
      @stagers  = dependencies[:stagers]
      @droplet_presenter = dependencies[:droplet_presenter]
      @apps_handler      = dependencies[:apps_handler]
    end

    get '/v3/packages', :list
    def list
      pagination_options = PaginationOptions.from_params(params)
      paginated_result   = @packages_handler.list(pagination_options, @access_context)
      packages_json      = @package_presenter.present_json_list(paginated_result, '/v3/packages')
      [HTTP::OK, packages_json]
    end

    post '/v3/packages/:guid/upload', :upload
    def upload(package_guid)
      message      = PackageUploadMessage.new(package_guid, params)
      valid, error = message.validate
      unprocessable!(error) if !valid

      package      = @packages_handler.upload(message, @access_context)
      package_json = @package_presenter.present_json(package)

      [HTTP::CREATED, package_json]
    rescue PackagesHandler::InvalidPackageType => e
      invalid_request!(e.message)
    rescue PackagesHandler::PackageNotFound
      package_not_found!
    rescue PackagesHandler::Unauthorized
      unauthorized!
    rescue PackagesHandler::BitsAlreadyUploaded
      bits_already_uploaded!
    end

    get '/v3/packages/:guid', :show
    def show(guid)
      package = @packages_handler.show(guid, @access_context)
      package_not_found! if package.nil?

      package_json = @package_presenter.present_json(package)
      [HTTP::OK, package_json]
    rescue PackagesHandler::Unauthorized
      unauthorized!
    end

    delete '/v3/packages/:guid', :delete
    def delete(guid)
      check_write_permissions!

      package_delete_fetcher = PackageDeleteFetcher.new(current_user)
      package_dataset        = package_delete_fetcher.fetch(guid)
      package_not_found! if package_dataset.empty?

      PackageDelete.new.delete(package_dataset)

      [HTTP::NO_CONTENT]
    end

    post '/v3/packages/:guid/droplets', :stage
    def stage(package_guid)
      check_write_permissions!

      staging_message = StagingMessage.create_from_http_request(package_guid, body)
      valid, error    = staging_message.validate
      unprocessable!(error) if !valid

      package, app, space, buildpack = package_stage_fetcher.fetch(package_guid, staging_message.buildpack_guid)
      package_not_found! if package.nil?
      app_not_found! if app.nil?
      space_not_found! if space.nil?
      buildpack_not_found! if buildpack.nil? && staging_message.buildpack_guid

      droplet = package_stage_action.stage(package, app, space, buildpack, staging_message, @stagers)

      [HTTP::CREATED, @droplet_presenter.present_json(droplet)]
    rescue PackageStageAction::InvalidPackage => e
      invalid_request!(e.message)
    end

    def package_stage_action
      PackageStageAction.new
    end

    def package_stage_fetcher
      PackageStageFetcher.new(current_user)
    end

    private

    def package_not_found!
      raise VCAP::Errors::ApiError.new_from_details('ResourceNotFound', 'Package not found')
    end

    def buildpack_not_found!
      raise VCAP::Errors::ApiError.new_from_details('ResourceNotFound', 'Buildpack not found')
    end

    def app_not_found!
      raise VCAP::Errors::ApiError.new_from_details('ResourceNotFound', 'App not found ')
    end

    def space_not_found!
      raise VCAP::Errors::ApiError.new_from_details('ResourceNotFound', 'Space not found')
    end

    def unauthorized!
      raise VCAP::Errors::ApiError.new_from_details('NotAuthorized')
    end

    def bits_already_uploaded!
      raise VCAP::Errors::ApiError.new_from_details('PackageBitsAlreadyUploaded')
    end

    def unprocessable!(message)
      raise VCAP::Errors::ApiError.new_from_details('UnprocessableEntity', message)
    end

    def invalid_request!(message)
      raise VCAP::Errors::ApiError.new_from_details('InvalidRequest', message)
    end
  end
end
