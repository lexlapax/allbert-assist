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
  def click(state, selector, opts) do
    label = Keyword.get(opts, :visible_label_preview) || "Stub clickable element"

    {:ok,
     %{
       state: state,
       click: %{
         selector: selector,
         visible_label_preview: label,
         navigation_triggered?: false,
         url: List.first(state.pages)
       }
     }}
  end

  @impl true
  def extract(state, format, opts) do
    max_bytes = Keyword.get(opts, :max_bytes, 4096)
    body = body_for(state, format)
    text = binary_part(body, 0, min(byte_size(body), max_bytes))

    {:ok,
     %{
       format: format,
       text: text,
       content: text,
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
       content: "stub screenshot for #{List.first(state.pages) || "about:blank"}",
       bytes: 128,
       redacted_credential_inputs?: true
     }}
  end

  @impl true
  def close(_state), do: :ok

  defp body_for(state, :pdf) do
    url = List.first(state.pages) || "about:blank"

    """
    %PDF-1.4
    1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
    2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
    3 0 obj << /Type /Page /Parent 2 0 R /Contents 4 0 R >> endobj
    4 0 obj << /Length 72 >> stream
    BT /F1 12 Tf 72 720 Td (Stub PDF extraction for #{url}) Tj ET
    endstream endobj
    trailer << /Root 1 0 R >>
    %%EOF
    """
  end

  defp body_for(state, :text) do
    "Stub browser extraction for #{List.first(state.pages) || "about:blank"}"
  end

  defp body_for(state, _format) do
    url = List.first(state.pages) || "about:blank"

    """
    <html>
      <body>
        <h1>Stub page</h1>
        <p>Stub browser extraction for #{url}</p>
        <ul><li>first item</li><li>second item</li></ul>
        <pre><code>sample_code()</code></pre>
      </body>
    </html>
    """
  end
end
