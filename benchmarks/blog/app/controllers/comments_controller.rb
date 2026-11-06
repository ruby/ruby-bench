class CommentsController < ApplicationController
  before_action :set_article

  def create
    @comment = @article.comments.build(comment_params)
    if @comment.save
      redirect_to @article, notice: "Comment was successfully created."
    else
      redirect_to @article, alert: "Could not create comment."
    end
  end

  def destroy
    @comment = @article.comments.find(params.expect(:id))
    @comment.destroy
    redirect_to @article, notice: "Comment was successfully deleted."
  end

  private

    def set_article
      @article = Article.find(params.expect(:article_id))
    end

    def comment_params
      params.expect(comment: [ :commenter, :body ])
    end
end
