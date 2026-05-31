defmodule AllbertBrowser.Extractors.PDF do
  @moduledoc false

  alias AllbertBrowser.Extractors.HTML

  def extract(source, opts) when is_binary(source) do
    max_pages = Keyword.fetch!(opts, :pdf_max_pages)
    timeout_ms = Keyword.fetch!(opts, :pdf_parse_timeout_ms)

    cond do
      timeout_ms <= 0 ->
        {:error, :pdf_parse_timeout}

      not String.starts_with?(source, "%PDF") ->
        {:error, :malformed_pdf}

      String.contains?(source, "/Encrypt") ->
        {:error, :encrypted_pdf}

      page_count(source) > max_pages ->
        {:error, :pdf_page_cap_exceeded}

      true ->
        extract_text_layer(source, Keyword.fetch!(opts, :max_bytes))
    end
  end

  def extract(_source, _opts), do: {:error, :invalid_pdf_source}

  defp extract_text_layer(source, max_bytes) do
    text =
      source
      |> literal_text_fragments()
      |> Enum.join(" ")
      |> String.trim()

    if text == "" do
      {:error, :unsupported_pdf_text_layer}
    else
      HTML.bounded(:pdf, text, max_bytes)
    end
  end

  defp literal_text_fragments(source) do
    tj =
      Regex.scan(~r/\(([^()]*)\)\s*Tj/s, source)
      |> Enum.map(fn [_match, text] -> unescape(text) end)

    tj_array =
      Regex.scan(~r/\[(.*?)\]\s*TJ/s, source)
      |> Enum.flat_map(fn [_match, array] ->
        Regex.scan(~r/\(([^()]*)\)/s, array)
        |> Enum.map(fn [_match, text] -> unescape(text) end)
      end)

    tj ++ tj_array
  end

  defp page_count(source) do
    source
    |> then(&Regex.scan(~r/\/Type\s*\/Page\b/, &1))
    |> length()
    |> max(1)
  end

  defp unescape(text) do
    text
    |> String.replace("\\(", "(")
    |> String.replace("\\)", ")")
    |> String.replace("\\\\", "\\")
    |> String.replace(~r/\\[nrtbf]/, " ")
  end
end
