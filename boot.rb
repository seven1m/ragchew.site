require 'bundler/setup'

require 'active_record'
require 'dotenv'
require 'erubi'
require 'dotiw'
require 'cgi'
require 'erb'
require 'google/cloud/firestore'
require 'honeybadger'
require 'json'
require 'net/http'
require 'nokogiri'
require 'pusher'
require 'redcarpet'
require 'redis'
require 'time'
require 'uri'
require 'yaml'
require 'with_advisory_lock'

dotenv_env = ENV['RACK_ENV'] || 'development'
dotenv_files = [".env.#{dotenv_env}"]
dotenv_files << '.env'
Dotenv.load(*dotenv_files)

template = eval(Erubi::Engine.new(File.read('config/database.yaml')).src)
db_config = YAML.safe_load(template)
env = case ENV['RACK_ENV']
      when 'production'
        :production
      when 'test'
        :test
      else
        :development
      end
ActiveRecord::Base.establish_connection(db_config[env.to_s])
ActiveRecord::Base.logger = Logger.new($stderr) if ENV['DEBUG_SQL']

require_relative './lib/associate_club_with_nets'
require_relative './lib/associate_net_with_club'
require_relative './lib/extensions'
require_relative './lib/fetcher'
require_relative './lib/grid_square'
require_relative './lib/net_info'
require_relative './lib/net_like'
require_relative './lib/backend'
require_relative './lib/net_list'
require_relative './lib/qrz'
require_relative './lib/qrz_auto_session'
require_relative './lib/review_demo'
require_relative './lib/station_updater'
require_relative './lib/tables'
require_relative './lib/update_club_list'

CURRENT_GIT_SHA = ENV['GIT_REV'] || `git rev-parse HEAD`.strip

redis_uri = URI(ENV.fetch('REDIS_URL'))
if redis_uri.path.nil? || redis_uri.path.empty? || redis_uri.path == '/'
  redis_uri.path = "/#{ENV.fetch('REDIS_DB', '1')}"
end
REDIS = Redis.new(url: redis_uri.to_s)

# Set APPLE_REVIEW_DEMO_ENABLED = false after review is approved
APPLE_REVIEW_DEMO_ENABLED  = ENV['APPLE_REVIEW_DEMO_ENABLED'] == 'true'
APPLE_REVIEW_DEMO_CALL_SIGN = 'X0REV'
APPLE_REVIEW_DEMO_PASSWORD = ENV.fetch('APPLE_REVIEW_DEMO_PASSWORD')
APPLE_REVIEW_DEMO_NET_NAME = 'RagChew App Testing Review Net'
