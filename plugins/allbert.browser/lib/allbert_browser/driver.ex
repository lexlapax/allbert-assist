defmodule AllbertBrowser.Driver do
  @moduledoc """
  Driver facade for browser sessions.
  """

  @callback verify(keyword()) :: {:ok, map()} | {:error, term()}
  @callback start_session(keyword()) :: {:ok, term()} | {:error, term()}
  @callback navigate(term(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback click(term(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback fill(term(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback download(term(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback extract(term(), atom(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback screenshot(term(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback close(term()) :: :ok | {:error, term()}

  def module(opts \\ []) do
    Keyword.get(opts, :driver) ||
      Application.get_env(:allbert_browser, :driver) ||
      if AllbertAssist.RuntimeEnv.test?() do
        AllbertBrowser.Driver.Stub
      else
        AllbertBrowser.Driver.Playwright
      end
  end

  def verify(opts \\ []), do: module(opts).verify(opts)
  def start_session(opts \\ []), do: module(opts).start_session(opts)
  def navigate(driver_state, url, opts \\ []), do: module(opts).navigate(driver_state, url, opts)

  def click(driver_state, selector, opts \\ []),
    do: module(opts).click(driver_state, selector, opts)

  def fill(driver_state, selector, opts \\ []),
    do: module(opts).fill(driver_state, selector, opts)

  def download(driver_state, url, opts \\ []),
    do: module(opts).download(driver_state, url, opts)

  def extract(driver_state, format, opts \\ []),
    do: module(opts).extract(driver_state, format, opts)

  def screenshot(driver_state, opts \\ []), do: module(opts).screenshot(driver_state, opts)
  def close(driver_state, opts \\ []), do: module(opts).close(driver_state)
end
