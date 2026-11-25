class Comment < ApplicationRecord
  belongs_to :article

  validates :commenter, presence: true
  validates :body, presence: true

  # Broadcast comment changes to article show page subscribers
  # Lambda receives the record being broadcast
  broadcasts_to ->(comment) { "article_#{comment.article_id}_comments" }, target: "comments"

  # Also update article on index when comments change (for comment count)
  # rescue nil: during seeding, URL helpers aren't available but no one is listening anyway
  after_create_commit { article.broadcast_replace_to("articles") rescue nil }
  after_destroy_commit { article.broadcast_replace_to("articles") rescue nil }
end
