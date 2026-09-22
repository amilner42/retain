defmodule Retain.Review do
  @moduledoc """
  One row of the log. Append-only: Retain never updates or deletes one, and every other piece of
  state is a fold over them.

  Most rows are attempts. Two are not:

    * a `:defer` row (`Retain.defer/4`) moves `due` to `until` and leaves the ladder alone;
    * an **amendment** (`Retain.amend/5`) has `supersedes_id` set and corrects the outcome of the
      row it names, in that row's place in time.

  `Retain.Log` resolves both before the fold sees them.

  `meta` is an opaque map for whatever the host wants to keep about the attempt (what was
  answered, how long it took). Retain stores it and never reads it.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "retain_reviews" do
    belongs_to :item, Retain.Item
    belongs_to :supersedes, __MODULE__, foreign_key: :supersedes_id

    field :outcome, Ecto.Enum, values: [:pass, :partial, :fail, :again, :known, :defer]
    field :at, :utc_datetime_usec
    field :until, :utc_datetime_usec
    field :meta, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
