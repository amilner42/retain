defmodule Retain.DeleteUserTest do
  @moduledoc "Removing a learner: the one thing a host needs for a deletion request."
  use Retain.DataCase, async: true

  alias Retain.{Item, Review, User}

  test "takes the learner's items and their whole log with them" do
    user!()
    items!("u1", ["a", "b"])
    review!("u1", "a", :pass, at: t0())
    {:ok, %{review_id: id}} = Retain.review("u1", "a", :fail, at: days(1))
    {:ok, _} = Retain.amend("u1", "a", id, :pass, at: days(1))
    {:ok, _} = Retain.defer("u1", "b", days(30), at: t0())

    assert {:ok, %{items: 2, reviews: 4}} = Retain.delete_user("u1")

    assert {:error, :not_found} = Retain.fetch_user("u1")
    assert Repo.aggregate(Item, :count) == 0
    assert Repo.aggregate(Review, :count) == 0
    assert Repo.aggregate(User, :count) == 0
  end

  test "leaves every other learner alone, including one with the same uid in another scope" do
    user!("keep")
    items!("keep", ["a"])
    review!("keep", "a", :pass, at: t0())

    user!("u1", scope: "other")
    items!("u1", ["a"], scope: "other")
    review!("u1", "a", :pass, at: t0(), scope: "other")

    user!("u1")
    items!("u1", ["a"])

    assert {:ok, %{items: 1, reviews: 0}} = Retain.delete_user("u1")

    assert {:ok, _} = Retain.fetch_user("keep")
    assert {:ok, _} = Retain.fetch_user("u1", scope: "other")
    assert {:error, :not_found} = Retain.fetch_user("u1")
    assert Repo.aggregate(Item, :count) == 2
    assert Repo.aggregate(Review, :count) == 2
  end

  test "an unknown learner is not found, and nothing is written" do
    user!()
    items!("u1", ["a"])

    assert {:error, :not_found} = Retain.delete_user("nobody")
    assert {:error, :not_found} = Retain.delete_user("u1", scope: "other")
    assert Repo.aggregate(Item, :count) == 1
  end
end
