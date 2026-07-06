defmodule AllbertAssist.RuntimeEnv do
  @moduledoc """
  Release-safe build/runtime environment detection (v0.62 M1).

  The pre-v0.62 pattern probed `Mix.env()` at runtime — but Mix is absent in
  an OTP release, so every such check silently returned false and, for
  example, the settings master-key enforcement degraded to the dev-style key
  file inside the packaged artifact (Current Code State 6 in the v0.62 plan).

  `build_env/0` reads the value `config/config.exs` bakes from `config_env()`
  at build time (`:prod` for releases, `:test`/`:dev` under Mix), so the
  semantics hold with or without Mix loaded. `release?/0` detects the OTP
  release itself via the env the release scripts export.
  """

  @doc "The compile-config environment this build was made with."
  @spec build_env() :: :dev | :test | :prod
  def build_env do
    Application.get_env(:allbert_assist, :env, :dev)
  end

  @doc "True in MIX_ENV=prod builds — including packaged releases."
  @spec prod?() :: boolean()
  def prod?, do: build_env() == :prod

  @doc "True in MIX_ENV=test builds."
  @spec test?() :: boolean()
  def test?, do: build_env() == :test

  @doc "True when running inside an OTP release (packaged artifact)."
  @spec release?() :: boolean()
  def release? do
    is_binary(System.get_env("RELEASE_NAME"))
  end
end
