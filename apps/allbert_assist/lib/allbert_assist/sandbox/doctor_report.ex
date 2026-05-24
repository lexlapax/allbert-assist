defmodule AllbertAssist.Sandbox.DoctorReport do
  @moduledoc """
  Structured report returned by `AllbertAssist.Sandbox.doctor/1`.
  """

  alias AllbertAssist.Sandbox.Policy

  defstruct status: :unavailable,
            enabled?: false,
            configured_backend: "auto",
            resolved_backend: nil,
            candidates: [],
            settings: %{},
            roots: %{},
            host: %{},
            diagnostics: []

  @type t :: %__MODULE__{
          status: :available | :disabled | :unavailable,
          enabled?: boolean(),
          configured_backend: String.t(),
          resolved_backend: atom() | nil,
          candidates: [map()],
          settings: map(),
          roots: map(),
          host: map(),
          diagnostics: [map()]
        }

  @spec disabled(Policy.t()) :: t()
  def disabled(%Policy{} = policy) do
    %__MODULE__{
      status: :disabled,
      enabled?: false,
      configured_backend: policy.backend,
      settings: Policy.summary(policy),
      roots: policy.roots,
      host: Map.from_struct(policy.host),
      diagnostics: [%{reason: :sandbox_disabled, setting: "sandbox.elixir.enabled"}]
    }
  end

  @spec from_resolution(map(), Policy.t()) :: t()
  def from_resolution(resolution, %Policy{} = policy) when is_map(resolution) do
    resolved_backend = Map.get(resolution, :resolved_backend)

    %__MODULE__{
      status: if(is_nil(resolved_backend), do: :unavailable, else: :available),
      enabled?: policy.enabled?,
      configured_backend: policy.backend,
      resolved_backend: resolved_backend,
      candidates: Map.get(resolution, :candidates, []),
      settings: Policy.summary(policy),
      roots: policy.roots,
      host: Map.from_struct(policy.host),
      diagnostics: Map.get(resolution, :diagnostics, [])
    }
  end
end
