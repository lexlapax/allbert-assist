defmodule AllbertBrowser.Driver.Stub do
  @moduledoc false

  @behaviour AllbertBrowser.Driver

  @impl true
  def verify(_opts) do
    {:ok,
     %{
       driver: "stub",
       browser: "stub-chromium",
       live_check_status: :ok,
       capabilities: [:navigate, :extract, :screenshot]
     }}
  end

  @impl true
  def start_session(opts) do
    {:ok,
     %{
       id: Keyword.fetch!(opts, :session_id),
       pages: [],
       redacted_inputs?: false
     }}
  end

  @impl true
  def navigate(state, url, _opts) do
    {:ok,
     %{
       state: %{state | pages: [url | state.pages]},
       page_meta: %{url: url, title: "Stub page", status: 200, redirected_to: nil}
     }}
  end

  @impl true
  def extract(state, format, opts) do
    max_bytes = Keyword.get(opts, :max_bytes, 4096)
    body = "Stub browser extraction for #{List.first(state.pages) || "about:blank"}"
    text = String.slice(body, 0, max_bytes)

    {:ok,
     %{
       format: format,
       text: text,
       bytes: byte_size(text),
       truncated?: byte_size(body) > byte_size(text)
     }}
  end

  @impl true
  def screenshot(state, _opts) do
    {:ok,
     %{
       state: %{state | redacted_inputs?: true},
       screenshot_ref: "cache://browser/#{state.id}/stub-screenshot.png",
       bytes: 128,
       redacted_credential_inputs?: true
     }}
  end

  @impl true
  def close(_state), do: :ok
end
