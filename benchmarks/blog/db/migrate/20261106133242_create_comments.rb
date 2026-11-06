class CreateComments < ActiveRecord::Migration[8.1]
  def change
    create_table :comments do |t|
      t.references :article, null: false, foreign_key: true
      t.string :commenter
      t.text :body

      t.timestamps
    end
  end
end
