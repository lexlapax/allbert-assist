defmodule AllbertBrowser.Extractors.Markdown do
  @moduledoc false

  alias AllbertBrowser.Extractors.{HTML, Text}

  def extract(source, opts) when is_binary(source) do
    markdown =
      source
      |> protect_code_blocks()
      |> headings()
      |> list_items()
      |> paragraphs()
      |> Text.strip_tags()
      |> Text.decode_entities()
      |> Text.normalize_space()
      |> restore_code_fences()

    HTML.bounded(:markdown, markdown, Keyword.fetch!(opts, :max_bytes))
  end

  def extract(_source, _opts), do: {:error, :invalid_markdown_source}

  defp headings(source) do
    Enum.reduce(1..6, source, fn level, acc ->
      Regex.replace(~r/<h#{level}\b[^>]*>(.*?)<\/h#{level}>/is, acc, fn _match, body ->
        "\n#{String.duplicate("#", level)} #{Text.strip_tags(body)}\n"
      end)
    end)
  end

  defp list_items(source) do
    Regex.replace(~r/<li\b[^>]*>(.*?)<\/li>/is, source, fn _match, body ->
      "\n- #{Text.strip_tags(body)}"
    end)
  end

  defp paragraphs(source) do
    Regex.replace(~r/<p\b[^>]*>(.*?)<\/p>/is, source, fn _match, body ->
      "\n#{Text.strip_tags(body)}\n"
    end)
  end

  defp protect_code_blocks(source) do
    Regex.replace(~r/<pre\b[^>]*>\s*<code\b[^>]*>(.*?)<\/code>\s*<\/pre>/is, source, fn _match,
                                                                                        code ->
      "\nALLBERT_CODE_FENCE_START\n#{Text.decode_entities(code)}\nALLBERT_CODE_FENCE_END\n"
    end)
  end

  defp restore_code_fences(source) do
    source
    |> String.replace("ALLBERT_CODE_FENCE_START", "```")
    |> String.replace("ALLBERT_CODE_FENCE_END", "```")
  end
end
