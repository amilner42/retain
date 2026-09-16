defmodule Retain.TestRepo do
  use Ecto.Repo, otp_app: :retain, adapter: Ecto.Adapters.Postgres
end
