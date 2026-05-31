defmodule AllbertBrowser.Driver.Playwright do
  @moduledoc """
  Playwright driver placeholder.

  The concrete Node/Playwright bridge is exercised in the opt-in
  `external-smoke` lane. Release tests use `AllbertBrowser.Driver.Stub`.
  """

  @behaviour AllbertBrowser.Driver

  @impl true
  def verify(_opts), do: {:error, :playwright_bridge_unavailable}

  @impl true
  def start_session(_opts), do: {:error, :playwright_bridge_unavailable}

  @impl true
  def navigate(_state, _url, _opts), do: {:error, :playwright_bridge_unavailable}

  @impl true
  def click(_state, _selector, _opts), do: {:error, :playwright_bridge_unavailable}

  @impl true
  def extract(_state, _format, _opts), do: {:error, :playwright_bridge_unavailable}

  @impl true
  def screenshot(_state, _opts), do: {:error, :playwright_bridge_unavailable}

  @impl true
  def close(_state), do: :ok
end
