defmodule AllbertAssist.Sandbox.Backend do
  @moduledoc """
  Behaviour for v0.36 sandbox container backends.

  Backends receive normalized sandbox data and must invoke container engines
  with explicit executable plus argv. They must not call a shell.
  """

  alias AllbertAssist.Sandbox.Policy

  @callback id() :: atom()
  @callback platforms() :: [atom()]
  @callback available?(Policy.t()) :: boolean()
  @callback doctor(Policy.t()) :: map()
  @callback run(term(), term(), Policy.t()) :: {:ok, term()} | {:error, term()}
  @callback cleanup(term()) :: :ok | {:error, term()}
end
