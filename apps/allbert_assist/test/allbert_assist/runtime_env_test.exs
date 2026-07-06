defmodule AllbertAssist.RuntimeEnvTest do
  @moduledoc """
  v0.62 M1 — release-safe env detection. The old `Mix.env()` probes returned
  false inside an OTP release (Mix absent), silently disabling master-key
  enforcement and mis-selecting drivers; `build_env/0` reads the value baked
  by `config/config.exs` so the semantics hold with or without Mix.
  """
  use ExUnit.Case, async: true

  alias AllbertAssist.RuntimeEnv

  test "build_env reflects the compile-config environment (test here)" do
    assert RuntimeEnv.build_env() == :test
    assert RuntimeEnv.test?()
    refute RuntimeEnv.prod?()
  end

  test "the config value is baked, not probed from Mix" do
    # The value comes from Application env (config.exs `env: config_env()`),
    # not a runtime Mix call — so it survives a release where Mix is absent.
    assert Application.get_env(:allbert_assist, :env) == :test
  end

  test "release? keys off RELEASE_NAME" do
    saved = System.get_env("RELEASE_NAME")
    System.delete_env("RELEASE_NAME")
    refute RuntimeEnv.release?()

    System.put_env("RELEASE_NAME", "allbert")
    assert RuntimeEnv.release?()

    case saved do
      nil -> System.delete_env("RELEASE_NAME")
      value -> System.put_env("RELEASE_NAME", value)
    end
  end
end
