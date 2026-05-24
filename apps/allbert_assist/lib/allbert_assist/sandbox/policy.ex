defmodule AllbertAssist.Sandbox.Policy do
  @moduledoc """
  Settings Central-backed operator policy for the v0.36 Elixir/OTP sandbox.
  """

  alias AllbertAssist.Paths
  alias AllbertAssist.Sandbox.Host
  alias AllbertAssist.Settings

  @enforce_keys [
    :enabled?,
    :backend,
    :image,
    :network,
    :cpu_limit,
    :memory_mb,
    :timeout_ms,
    :output_bytes,
    :roots,
    :host
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          enabled?: boolean(),
          backend: String.t(),
          image: String.t(),
          network: String.t(),
          cpu_limit: number(),
          memory_mb: pos_integer(),
          timeout_ms: pos_integer(),
          output_bytes: pos_integer(),
          roots: map(),
          host: Host.t()
        }

  @spec load!(keyword()) :: t()
  def load!(opts \\ []) do
    %__MODULE__{
      enabled?: setting("sandbox.elixir.enabled", false),
      backend: setting("sandbox.elixir.backend", "auto"),
      image: setting("sandbox.elixir.image", "allbert-elixir-otp:local"),
      network: setting("sandbox.elixir.network", "none"),
      cpu_limit: setting("sandbox.elixir.cpu_limit", 1.0),
      memory_mb: setting("sandbox.elixir.memory_mb", 1024),
      timeout_ms: setting("sandbox.elixir.timeout_ms", 120_000),
      output_bytes: setting("sandbox.elixir.output_bytes", 65_536),
      roots: roots(),
      host: Keyword.get(opts, :host, Host.current())
    }
  end

  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = policy) do
    %{
      enabled?: policy.enabled?,
      backend: policy.backend,
      image: policy.image,
      network: policy.network,
      cpu_limit: policy.cpu_limit,
      memory_mb: policy.memory_mb,
      timeout_ms: policy.timeout_ms,
      output_bytes: policy.output_bytes
    }
  end

  defp roots do
    %{
      home: Paths.home(),
      sandbox: Paths.sandbox_root(),
      bundles: Paths.sandbox_bundles_root(),
      reports: Paths.sandbox_reports_root(),
      cache: Paths.sandbox_cache_root()
    }
  end

  defp setting(key, default) do
    case Settings.get(key) do
      {:ok, value} -> value
      {:error, _reason} -> default
    end
  rescue
    _exception -> default
  end
end
