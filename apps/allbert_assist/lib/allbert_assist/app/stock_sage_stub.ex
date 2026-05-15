defmodule AllbertAssist.App.StockSageStub do
  @moduledoc false

  use AllbertAssist.App

  @impl true
  def app_id, do: :stocksage

  @impl true
  def display_name, do: "StockSage (placeholder)"

  @impl true
  def version, do: "0.18.0"

  @impl true
  def validate(_opts), do: :ok
end
