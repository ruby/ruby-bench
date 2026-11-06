require "test_helper"

class ArticlesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @article = articles(:one)
  end

  test "should get index" do
    get articles_url
    assert_response :success
    assert_select "h1", "Articles"
    assert_select "#articles" do
      assert_select "h2", minimum: 1
    end
  end

  test "should get new" do
    get new_article_url
    assert_response :success
    assert_select "form"
  end

  test "should create article" do
    assert_difference("Article.count") do
      post articles_url, params: { article: { body: "A sufficiently long body for validation.", title: "New Title" } }
    end

    assert_redirected_to article_url(Article.last)
    assert_equal "New Title", Article.last.title
  end

  test "should not create article with invalid params" do
    assert_no_difference("Article.count") do
      post articles_url, params: { article: { title: "", body: "" } }
    end

    assert_response :unprocessable_entity
  end

  test "should show article" do
    get article_url(@article)
    assert_response :success
    assert_select "h1", @article.title
    assert_select "h2", "Comments"
    assert_select "#comments .p-4", minimum: 1
  end

  test "should get edit" do
    get edit_article_url(@article)
    assert_response :success
    assert_select "form"
  end

  test "should update article" do
    patch article_url(@article), params: { article: { body: @article.body, title: "Updated Title" } }
    assert_redirected_to article_url(@article)
    @article.reload
    assert_equal "Updated Title", @article.title
  end

  test "should not update article with invalid params" do
    patch article_url(@article), params: { article: { title: "", body: "" } }
    assert_response :unprocessable_entity
  end

  test "should destroy article" do
    assert_difference("Article.count", -1) do
      delete article_url(@article)
    end

    assert_redirected_to articles_url
  end
end
