defmodule AllbertAssist.Session.AppId do
  @moduledoc """
  v0.14 static active-app allowlist.

  v0.15 replaces this with app-registry validation. Until then, binary input
  is matched against this allowlist before `String.to_existing_atom/1` is used.
  """

  @known_atoms [:allbert, :stocksage]
  @nil_aliases ["", "none", "general"]
  @known_strings Enum.map(@known_atoms, &Atom.to_string/1)

  @type t :: :allbert | :stocksage | nil

  @doc "Normalize CLI/action/channel app id input without creating atoms."
  @spec normalize(term()) :: {:ok, t()} | {:error, :unknown_app}
  def normalize(nil), do: {:ok, nil}

  def normalize(app_id) when is_atom(app_id) do
    cond do
      app_id in @known_atoms -> {:ok, app_id}
      app_id in [:none, :general] -> {:ok, nil}
      true -> {:error, :unknown_app}
    end
  end

  def normalize(app_id) when is_binary(app_id) do
    normalized =
      app_id
      |> String.trim()
      |> String.downcase()

    cond do
      normalized in @nil_aliases ->
        {:ok, nil}

      normalized in @known_strings ->
        {:ok, String.to_existing_atom(normalized)}

      true ->
        {:error, :unknown_app}
    end
  rescue
    ArgumentError -> {:error, :unknown_app}
  end

  def normalize(_app_id), do: {:error, :unknown_app}

  @doc "Return a stable display label."
  @spec label(t() | atom()) :: String.t()
  def label(nil), do: "none"
  def label(app_id) when app_id in @known_atoms, do: Atom.to_string(app_id)
  def label(_app_id), do: "unknown"
end
