require_relative "../../lib/harness/loader"
require "securerandom" # Provides `Random::Formatter` in Ruby 2.6+

Dir.chdir __dir__
use_gemfile

require "sequel"

if RUBY_ENGINE == "jruby"
  DB = Sequel.connect("jdbc:sqlite::memory:")
else
  DB = Sequel.sqlite
end

DB.create_table :posts do
  primary_key :id
  String :title, null: false
  String :body
  String :type_name, null: false
  String :key, null: false
  Integer :upvotes, null: false
  Integer :author_id, null: false
  DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
end

Sequel::Model.plugin :timestamps, update_on_create: true 

class Post < Sequel::Model 
end

10000.times {
  Post.create(title: Random.alphanumeric(30),
              type_name: Random.alphanumeric(10),
              key: Random.alphanumeric(10),
              body: Random.alphanumeric(100),
              upvotes: rand(30),
              author_id: rand(30))
}

# heat any caches
Post[1].title

run_benchmark(200) do
  1.upto(1000) do |i|
    post = Post[i]
    "#{post.title}\n#{post.body}" \
    "type: #{post.type_name}, votes: #{post.upvotes}, updated on: #{post.updated_at}"
  end
end
