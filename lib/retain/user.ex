defmodule Retain.User do
  @moduledoc """
  A learner, identified by whatever id the host app already uses (`uid`), within a `scope`.

  Retain does no authentication. `tz` is the learner's IANA timezone and drives every calendar
  date Retain computes for them. `new_per_day` caps how many new items `Retain.queue/2`
  introduces per local day.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "retain_users" do
    field :scope, :string
    field :uid, :string
    field :tz, :string
    field :new_per_day, :integer

    has_many :items, Retain.Item

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:scope, :uid, :tz, :new_per_day])
    |> validate_required([:scope, :uid, :tz, :new_per_day])
    |> validate_number(:new_per_day, greater_than_or_equal_to: 0)
    |> validate_length(:uid, min: 1, max: 255)
    |> validate_length(:scope, min: 1, max: 255)
    |> validate_change(:tz, fn :tz, tz ->
      if Retain.Clock.valid?(tz), do: [], else: [tz: "is not a known IANA timezone"]
    end)
    |> unique_constraint([:scope, :uid], name: :retain_users_scope_uid_index)
  end
end
