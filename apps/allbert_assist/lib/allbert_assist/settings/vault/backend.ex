defmodule AllbertAssist.Settings.Vault.Backend do
  @moduledoc "Behaviour for a v0.62 M7 vault tier backend."

  @callback available?() :: boolean()
  @callback put(secret_ref :: String.t(), value :: String.t(), context :: map()) ::
              {:ok, map()} | {:error, term()}
  @callback get(secret_ref :: String.t(), context :: map()) ::
              {:ok, term()} | :missing | {:error, term()}
  @callback delete(secret_ref :: String.t(), context :: map()) :: {:ok, map()} | {:error, term()}
end
