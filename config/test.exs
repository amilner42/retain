import Config

config :retain, ecto_repos: [Retain.TestRepo]

config :retain, Retain.TestRepo,
  username: System.get_env("PGUSER") || "postgres",
  password: System.get_env("PGPASSWORD") || "postgres",
  hostname: System.get_env("PGHOST") || "localhost",
  database: "retain_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  priv: "priv/test_repo",
  log: false

config :retain, repo: Retain.TestRepo

config :logger, level: :warning
