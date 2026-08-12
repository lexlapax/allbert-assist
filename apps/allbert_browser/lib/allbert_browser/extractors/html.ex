defmodule AllbertBrowser.Extractors.HTML do
  @moduledoc false

  def extract(source, opts) when is_binary(source) do
    max_bytes = Keyword.fetch!(opts, :max_bytes)
    bounded(:html, source, max_bytes)
  end

  def extract(_source, _opts), do: {:error, :invalid_html_source}

  def bounded(format, source, max_bytes) do
    text = bounded_slice(source, max_bytes)

    {:ok,
     %{
       format: format,
       text: text,
       bytes: byte_size(text),
       truncated?: byte_size(source) > byte_size(text)
     }}
  end

  def bounded_slice(source, max_bytes) do
    source
    |> binary_part(0, min(byte_size(source), max_bytes))
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/, "")
  end
end
