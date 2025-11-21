require_relative '../../lib/harness/loader'

ENV['RAILS_ENV'] ||= 'production'
ENV['DISABLE_DATABASE_ENVIRONMENT_CHECK'] = '1' # Benchmarks don't really have 'production', so trash it at will.

Dir.chdir __dir__
use_gemfile

require_relative 'config/environment'
require_relative "route_generator"

# For an in-mem DB, we need to load all data on every boot
mem_db = ActiveRecord::Base.connection.raw_connection
file_db = SQLite3::Database.new('db/production.sqlite3')
b = SQLite3::Backup.new(mem_db, 'main', file_db, 'main')
b.step(-1) # import until finished
b.finish # destroy the Backup object

app = Rails.application
generator = RouteGenerator.new(app)
generator.routes # Make sure routes have been pregenerated

# Track ActiveRecord time
if ENV['TRACK_AR_TIME']
  ar_total_duration = 0.0
  process_start_t = Time.now

  # Track sql.active_record events
  ActiveSupport::Notifications.subscribe "sql.active_record" do |name, started, finished, unique_id, data|
    duration = finished - started
    ar_total_duration += duration
  end

  at_exit do
    process_duration = Time.now - process_start_t
    ar_percent = ar_total_duration * 100.0 / process_duration
    puts "ActiveRecord time: #{ar_total_duration.round(2)}s (#{ar_percent.round(2)}%) PID: #{Process.pid}"
  end
end

run_benchmark(10) do
  # Routes are from ./routes_generator.rb
  generator.routes.each_with_index do |env, idx|
    path = env["PATH_INFO"] # app.call mutates the path
    response_array = generator.visit(env) # Track HTTP cookies as we go along
    unless response_array.first == 200
      puts response_array.inspect
      raise "HTTP status is #{response_array.first} instead of 200 for req #{idx}/#{generator.routes.size}, #{path.inspect}. Is the benchmark app properly set up? See README.md."
    end
    response_array.last.close # Response might be a Rack::BodyProxy and MUST be closed.
  end
end

# This benchmark will keep writing the production log on every request. It adds up.
# Let's not fill the disk.
File.unlink(File.join(__dir__, "log/#{ENV['RAILS_ENV']}.log")) rescue nil
