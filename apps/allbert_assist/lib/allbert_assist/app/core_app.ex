defmodule AllbertAssist.App.CoreApp do
  @moduledoc false

  use AllbertAssist.App

  @impl true
  def app_id, do: :allbert

  @impl true
  def display_name, do: "Allbert"

  @impl true
  def version, do: "0.15.0"

  @impl true
  def validate(_opts), do: :ok
end
