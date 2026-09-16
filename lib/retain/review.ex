defmodule Retain.Review do
  @moduledoc """
  One attempt at an item. Append-only: Retain never updates or deletes a review, and every other
  piece of state is a fold over them.

  `meta` is an opaque map for whatever the host wants to keep about the attempt (what was
  answered, how long it took).
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "retain_reviews" do
    belongs_to :item, Retain.Item

    field :outcome, Ecto.Enum, values: [:pass, :partial, :fail]
    field :at, :utc_datetime_usec
    field :meta, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
