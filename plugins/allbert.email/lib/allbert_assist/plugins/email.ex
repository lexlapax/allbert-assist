defmodule AllbertAssist.Plugins.Email do
  @moduledoc false

  use AllbertAssist.Plugin

  @impl true
  def plugin_id, do: "allbert.email"

  @impl true
  def display_name, do: "Allbert Email Channel"

  @impl true
  def version, do: "0.17.0"

  @impl true
  def validate(_opts), do: :ok
end
