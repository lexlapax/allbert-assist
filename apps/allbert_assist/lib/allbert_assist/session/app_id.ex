defmodule AllbertAssist.Session.AppId do
  @moduledoc """
  Registry-backed active-app id normalization.

  Binary input is resolved through `AllbertAssist.App.Registry` without
  creating atoms from operator, model, channel, or job input.
  """

  alias AllbertAssist.App.Registry

  @type t :: atom() | nil

  @doc "Normalize CLI/action/channel app id input without creating atoms."
  @spec normalize(term()) :: {:ok, t()} | {:error, :unknown_app}
  def normalize(app_id), do: Registry.normalize_app_id(app_id)

  @doc "Return a stable display label."
  @spec label(t() | atom()) :: String.t()
  def label(nil), do: "none"

  def label(app_id) when is_atom(app_id) do
    if Registry.known_app_id?(app_id), do: Atom.to_string(app_id), else: "unknown"
  end

  def label(_app_id), do: "unknown"
end
