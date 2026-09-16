defmodule Retain.Item do
  @moduledoc """
  Something a learner is drilling, or will be.

  `key` is the host's identifier for it, unique per user. `tags` is a flat map of strings the
  host uses to filter and group. `content` is an opaque map Retain stores and returns but never
  reads. `position` orders new items for introduction (lowest first, then creation order).

  An item is `:new` until it is started (`started_at`), `:active` once in rotation, and
  `:suspended` while paused; see `status/1`.

  The ladder fields (`level`, `due`, `reps`, `lapses`, `last_reviewed_at`) are derived from the
  item's reviews and can be rebuilt from them at any time; see `Retain.rebuild/2`.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "retain_items" do
    belongs_to :user, Retain.User

    field :key, :string
    field :tags, :map, default: %{}
    field :content, :map, default: %{}
    field :suspended, :boolean, default: false
    field :started_at, :utc_datetime_usec
    field :position, :integer

    field :level, :integer, default: 0
    field :due, :utc_datetime_usec
    field :reps, :integer, default: 0
    field :lapses, :integer, default: 0
    field :last_reviewed_at, :utc_datetime_usec

    has_many :reviews, Retain.Review

    timestamps(type: :utc_datetime_usec)
  end

  @type status :: :new | :active | :suspended

  @doc "`:suspended` if paused, else `:new` until started, else `:active`."
  @spec status(t()) :: status()
  def status(%__MODULE__{suspended: true}), do: :suspended
  def status(%__MODULE__{started_at: nil}), do: :new
  def status(%__MODULE__{}), do: :active

  @doc false
  def changeset(item, attrs) do
    item
    |> cast(attrs, [:key, :tags, :content, :suspended, :position])
    |> validate_required([:key])
    |> validate_length(:key, min: 1, max: 1024)
    |> update_change(:tags, &normalize_tags/1)
    |> validate_change(:tags, &validate_tags/2)
    |> validate_change(:content, fn :content, content ->
      if is_map(content), do: [], else: [content: "must be a map"]
    end)
  end

  @doc """
  Turns atom keys and values into strings so `%{kind: :cube}` and `%{"kind" => "cube"}` store
  identically. Anything else is left for validation to reject.
  """
  @spec normalize_tags(term()) :: term()
  def normalize_tags(tags) when is_map(tags) do
    Map.new(tags, fn {k, v} -> {stringify(k), stringify(v)} end)
  end

  def normalize_tags(other), do: other

  defp stringify(v) when is_atom(v) and not is_nil(v) and not is_boolean(v), do: Atom.to_string(v)
  defp stringify(v), do: v

  defp validate_tags(:tags, tags) when is_map(tags) do
    if Enum.all?(tags, fn {k, v} -> is_binary(k) and k != "" and is_binary(v) end) do
      []
    else
      [tags: "must be a map of non-empty string keys to string values"]
    end
  end

  defp validate_tags(:tags, _), do: [tags: "must be a map"]
end
