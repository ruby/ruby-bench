require_relative "../../lib/harness/loader"

Dir.chdir __dir__
use_gemfile

require "active_record"

ActiveRecord::Base.establish_connection adapter: "sqlite3", database: ":memory:"

ActiveRecord::Schema.define do
  create_table :posts, force: true do |t|
    t.string :title, null: false
    t.string :body
    t.string :type_name, null: false
    t.string :key, null: false
    t.integer :upvotes, null: false
    t.integer :author_id, null: false
    t.timestamps
  end

  create_table :comments, force: true do |t|
    t.integer :post_id
    t.integer :author_id
    t.text :body
    t.string :tags
    t.datetime :published_at
    t.timestamps
  end
end

class Post < ActiveRecord::Base
  has_many :comments, inverse_of: :post
end

class Comment < ActiveRecord::Base
  belongs_to :post, inverse_of: :comments
end

Post.transaction do
  100.times do
    post = Post.create!(
      title: Random.alphanumeric(30),
      type_name: Random.alphanumeric(10),
      key: Random.alphanumeric(10),
      body: Random.alphanumeric(100),
      upvotes: rand(30),
      author_id: rand(30),
    )
    20.times do
      post.comments.create!(
        author_id: rand(30),
        body: Random.alphanumeric(30),
        tags: Random.alphanumeric(30),
        published_at: Time.now
      )
    end
  end
end

def run
  posts = Post.includes(:comments).order(id: :asc).limit(100)
  posts.each do |post|
    post.title
    post.title
    post.title
    post.body
    post.type_name
    post.upvotes
    post.updated_at
    post.comments.each do |comment|
      comment.body
      comment.published_at
    end
  end
end

run # heat any caches

run_benchmark(20) do
  10.times do
    run
  end
end
