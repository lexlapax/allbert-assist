defmodule AllbertBrowser.Extractors.Text do
  @moduledoc false

  alias AllbertBrowser.Extractors.HTML

  def extract(source, opts) when is_binary(source) do
    text =
      source
      |> strip_tags()
      |> decode_entities()
      |> normalize_space()

    HTML.bounded(:text, text, Keyword.fetch!(opts, :max_bytes))
  end

  def extract(_source, _opts), do: {:error, :invalid_text_source}

  def strip_tags(source) do
    source
    |> String.replace(~r/<script\b[^>]*>.*?<\/script>/is, " ")
    |> String.replace(~r/<style\b[^>]*>.*?<\/style>/is, " ")
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<\/(p|div|li|h[1-6]|tr)>/i, "\n")
    |> String.replace(~r/<[^>]+>/, " ")
  end

  def decode_entities(source) do
    source
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&nbsp;", " ")
  end

  def normalize_space(source) do
    source
    |> String.split(~r/[ \t\r\f\v]+/)
    |> Enum.join(" ")
    |> String.replace(~r/\n\s+/, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end
end
