# Sample articles and comments for the blog demo
# Seeds are idempotent - only run if database is empty
return if Article.count > 0

article1 = Article.create!(
  title: "Getting Started with Rails",
  body: "Rails is a web application framework running on the Ruby programming language. It makes building web apps faster and easier with conventions over configuration."
)

article1.comments.create!(
  commenter: "Alice",
  body: "Great introduction! Rails really does make development faster."
)

article1.comments.create!(
  commenter: "Bob",
  body: "I love how Rails handles database migrations automatically."
)

article2 = Article.create!(
  title: "Understanding MVC Architecture",
  body: "MVC stands for Model-View-Controller. Models handle data and business logic, Views display information to users, and Controllers coordinate between them."
)

article2.comments.create!(
  commenter: "Carol",
  body: "This pattern really helps keep code organized!"
)

article3 = Article.create!(
  title: "Ruby2JS: Rails Everywhere",
  body: "Ruby2JS transpiles Ruby to JavaScript, enabling Rails applications to run in browsers, on Node.js, and at the edge. Same code, different runtimes."
)

puts "Created #{Article.count} articles and #{Comment.count} comments"
