defmodule AllbertAssist.Plugin.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    metadata_opts =
      opts
      |> Keyword.delete(:name)
      |> maybe_name_metadata_supervisor(opts)

    Supervisor.init([{AllbertAssist.Plugin.MetadataSupervisor, metadata_opts}],
      strategy: :one_for_one
    )
  end

  defp maybe_name_metadata_supervisor(metadata_opts, opts) do
    if Keyword.get(opts, :name, __MODULE__) == __MODULE__ do
      Keyword.put_new(metadata_opts, :name, AllbertAssist.Plugin.MetadataSupervisor)
    else
      Keyword.put_new(metadata_opts, :name, nil)
    end
  end
end
