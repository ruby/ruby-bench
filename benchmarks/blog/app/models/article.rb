class Article < ApplicationRecord
  has_many :comments, dependent: :destroy

  # Broadcast article changes to index page subscribers
  # Lambda receives the record being broadcast
  broadcasts_to ->(_article) { "articles" }, inserts_by: :prepend

  validates :title, presence: true
  validates :body, presence: true, length: { minimum: 10 }
end
