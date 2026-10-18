ActiveRecord::Schema[8.0].define(version: 1) do
  create_table "invoices" do |t|
    t.datetime "closed_at"
    t.bigint "closed_by_id"
    t.datetime "created_at"
  end
end
