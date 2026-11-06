require "application_system_test_case"

class ArticlesSystemTest < ApplicationSystemTestCase
  test "full article lifecycle" do
    visit articles_url

    # Try to create with invalid data
    click_on "New article"
    click_button "Create Article"
    assert_text "prohibited this article from being saved"
    assert_text "can't be blank"

    # Fill in valid data and create
    fill_in "Title", with: "My First Article"
    fill_in "Body", with: "This is the body of my first article, long enough to pass validation."
    click_button "Create Article"
    assert_text "Article was successfully created"

    # Verify it appears on the index
    click_on "Back to articles"
    assert_text "My First Article"

    # View the article, then edit it
    click_on "My First Article"
    click_on "Edit this article"
    fill_in "Title", with: "My Updated Article"
    click_button "Update Article"
    assert_text "Article was successfully updated"
    assert_text "My Updated Article"

    # Delete the article
    accept_confirm do
      click_on "Destroy this article"
    end
    assert_text "Article was successfully destroyed"
    assert_no_text "My Updated Article"
  end

  test "article with comments" do
    visit articles_url

    # Create an article
    click_on "New article"
    fill_in "Title", with: "Article for Comments"
    fill_in "Body", with: "This article will have comments added and removed."
    click_button "Create Article"
    assert_text "Article was successfully created"

    # Add a comment
    fill_in "Commenter", with: "Alice"
    fill_in "Body", with: "Great article!"
    click_button "Add Comment"
    assert_text "Comment was successfully created"
    assert_text "Alice"
    assert_text "Great article!"

    # Delete the comment
    accept_confirm do
      click_button "Delete"
    end
    assert_text "Comment was successfully deleted"
    assert_no_text "Great article!"
  end
end
