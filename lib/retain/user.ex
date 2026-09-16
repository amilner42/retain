defmodule Retain.User do
  @moduledoc """
  A learner, identified by whatever id the host app already uses (`uid`), within a `scope`.

  Retain does no authentication. `tz` is the learner's IANA timezone and drives every calendar
  date Retain computes for them.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "retain_users" do
    field :scope, :string
    field :uid, :string
    field :tz, :string

    has_many :items, Retain.Item

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:scope, :uid, :tz])
    |> validate_required([:scope, :uid, :tz])
    |> validate_length(:uid, min: 1, max: 255)
    |> validate_length(:scope, min: 1, max: 255)
    |> validate_change(:tz, fn :tz, tz ->
      if Retain.Clock.valid?(tz), do: [], else: [tz: "is not a known IANA timezone"]
    end)
    |> unique_constraint([:scope, :uid], name: :retain_users_scope_uid_index)
  end
end
