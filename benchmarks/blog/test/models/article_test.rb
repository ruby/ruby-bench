require "test_helper"

class ArticleTest < ActiveSupport::TestCase
  test "creates an article with valid attributes" do
    article = articles(:one)
    assert_not_nil article.id
    assert_equal "Getting Started with Rails", article.title
  end

  test "validates title presence" do
    article = Article.new(title: "", body: "Valid body content here.")
    assert_not article.save
  end

  test "validates body minimum length" do
    article = Article.new(title: "Valid Title", body: "Short")
    assert_not article.save
  end

  test "destroys comments when article is destroyed" do
    article = articles(:one)
    assert_difference("Comment.count", -1) do
      article.destroy
    end
  end
end
