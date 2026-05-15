defmodule StockSage.DataCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  alias AllbertAssist.Repo
  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias AllbertAssist.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import StockSage.DataCase
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
