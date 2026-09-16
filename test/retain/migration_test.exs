defmodule Retain.MigrationTest do
  use Retain.DataCase, async: true

  test "the installed version is recorded on the users table" do
    assert %{rows: [["1"]]} =
             Repo.query!("SELECT obj_description('retain_users'::regclass, 'pg_class')")

    assert Retain.Migration.latest_version() == 1
  end

  test "the tables exist with their indexes" do
    %{rows: rows} =
      Repo.query!("SELECT indexname FROM pg_indexes WHERE tablename LIKE 'retain_%' ORDER BY 1")

    names = List.flatten(rows)
    assert "retain_users_scope_uid_index" in names
    assert "retain_items_user_id_key_index" in names
    assert "retain_items_tags_index" in names
    assert "retain_reviews_item_id_at_index" in names
    assert "retain_items_user_id_started_at_index" in names
  end

  test "deleting a user cascades to items and reviews" do
    user = user!()
    items!("u1", ["a"])
    review!("u1", "a", :pass)
    Repo.delete!(user)
    assert Repo.aggregate(Retain.Item, :count) == 0
    assert Repo.aggregate(Retain.Review, :count) == 0
  end
end
