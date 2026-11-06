require "test_helper"

class CommentTest < ActiveSupport::TestCase
  test "creates a comment on an article" do
    comment = comments(:one)
    assert_not_nil comment.id
    assert_equal articles(:one).id, comment.article_id
  end

  test "belongs to article association" do
    article = articles(:one)
    comment = article.comments.create(commenter: "Commenter", body: "Comment body text.")
    assert_equal article.id, comment.article_id
  end

  test "requires commenter" do
    article = articles(:one)
    comment = article.comments.build(body: "Comment without commenter")
    assert_not comment.save
  end

  test "requires body" do
    article = articles(:one)
    comment = article.comments.build(commenter: "Someone")
    assert_not comment.save
  end

  test "requires valid article" do
    comment = Comment.new(commenter: "Test", body: "A test comment.", article_id: 999999)
    assert_not comment.save
  end
end
