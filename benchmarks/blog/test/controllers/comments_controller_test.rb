require "test_helper"

class CommentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @article = articles(:one)
    @comment = comments(:one)
  end

  test "should create comment" do
    assert_difference("Comment.count") do
      post article_comments_url(@article), params: { comment: { commenter: "Test", body: "A test comment." } }
    end
    assert_redirected_to article_url(@article)
  end

  test "should not create comment with invalid params" do
    assert_no_difference("Comment.count") do
      post article_comments_url(@article), params: { comment: { commenter: "", body: "" } }
    end
    assert_redirected_to article_url(@article)
  end

  test "should destroy comment" do
    assert_difference("Comment.count", -1) do
      delete article_comment_url(@article, @comment)
    end
    assert_redirected_to article_url(@article)
  end
end
