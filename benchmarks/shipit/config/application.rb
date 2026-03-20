require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
# require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
# require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Shipit
  class Application < Rails::Application
    Pubsubstub.use_persistent_connections = false
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults "#{Rails::VERSION::MAJOR}.#{Rails::VERSION::MINOR}"

    config.active_job.queue_adapter = :test

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    config.assets.compile = false
    config.assets.manifest = "config/manifest.json"

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end

# Bencmark mods:
require "shipit"

module Shipit
  def secrets
    @secrets ||= build_secrets
  end

  FakeSecrets = Struct.new(:app_name, :user_access_tokens_key, :secret_key_base, :host, :redis_url, :github, keyword_init: true)
  GitHubConfig = Struct.new(:domain, :app_id, :installation_id, :webhook_secret, :private_key, :oauth, keyword_init: true)
  OauthConfig = Struct.new(:id, :secret, keyword_init: true)

  def build_secrets
    secrets = ActiveSupport::OrderedOptions.new
    secrets.app_name = "Shipit"
    secrets.user_access_tokens_key = "unused"
    secrets.secret_key_base = ENV.fetch('SECRET_KEY_BASE', "secret" * 20)
    secrets.host = "localhost"
    secrets.redis_url = "localhost" # Not actually used

    github = secrets.github = ActiveSupport::OrderedOptions.new
    github.domain = nil # defaults to github.com
    github.app_id = "random_unused_id"
    github.installation_id = "random_unused_id"
    github.webhook_secret = "random_unused_secret"
    github.private_key = "random_unused_secret"
    github.oauth = nil

    secrets
  end
end
#
# p Pubsubstub::StreamAction