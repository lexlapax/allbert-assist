defmodule AllbertAssist.Session.AppId do
  @moduledoc """
  Registry-backed active-app id normalization.

  Binary input is resolved through `AllbertAssist.App.Registry` without
  creating atoms from operator, model, channel, or job input.
  """

  alias AllbertAssist.App.Registry
  alias AllbertAssist.RegistryContext

  @type t :: atom() | nil

  @doc """
  Normalize CLI/action/channel app id input without creating atoms.

  `opts` may carry the internal ADR 0082 registry-context keyword; omission
  reads the global registry.
  """
  @spec normalize(term(), keyword()) :: {:ok, t()} | {:error, :unknown_app}
  def normalize(app_id, opts \\ []),
    do: Registry.normalize_app_id(app_id, RegistryContext.app_opts(opts))

  @doc """
  Normalize with a caller-owned error wrapper — the single source for the
  normalize-app-id-or-error variants (v1.0.2 M8.3; previously duplicated by
  `Intent.Handoff`, `Intent.Descriptor`, and `Intent.Candidate`).

  Success passes through as `{:ok, app_id}` (`nil` stays `{:ok, nil}` exactly
  as `normalize/2`). Any failure — an unknown app OR a registry exit — returns
  `{:error, wrap.(reason)}` so each caller keeps its documented error shape
  (`{:invalid_app_id, reason}` for Handoff/Descriptor,
  `{:unknown_app_id, input}` for Candidate).
  """
  @spec normalize_or(term(), keyword(), (term() -> term())) :: {:ok, t()} | {:error, term()}
  def normalize_or(app_id, opts, wrap) when is_function(wrap, 1) do
    case Registry.normalize_app_id(app_id, RegistryContext.app_opts(opts)) do
      {:ok, app_id} -> {:ok, app_id}
      {:error, reason} -> {:error, wrap.(reason)}
    end
  catch
    :exit, reason -> {:error, wrap.(reason)}
  end

  @doc "Return a stable display label."
  @spec label(t() | atom()) :: String.t()
  def label(nil), do: "none"

  def label(app_id) when is_atom(app_id) do
    if Registry.known_app_id?(app_id), do: Atom.to_string(app_id), else: "unknown"
  end

  def label(_app_id), do: "unknown"
end
