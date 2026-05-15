defmodule AllbertAssist.Plugins.Telegram do
  @moduledoc false

  use AllbertAssist.Plugin

  @impl true
  def plugin_id, do: "allbert.telegram"

  @impl true
  def display_name, do: "Allbert Telegram Channel"

  @impl true
  def version, do: "0.17.0"

  @impl true
  def validate(_opts), do: :ok
end
