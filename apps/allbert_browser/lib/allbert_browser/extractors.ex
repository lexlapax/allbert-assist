defmodule AllbertBrowser.Extractors do
  @moduledoc false

  alias AllbertBrowser.Extractors.{HTML, Markdown, PDF, Text}

  def extract(:html, source, opts), do: HTML.extract(source, opts)
  def extract(:text, source, opts), do: Text.extract(source, opts)
  def extract(:markdown, source, opts), do: Markdown.extract(source, opts)
  def extract(:pdf, source, opts), do: PDF.extract(source, opts)
  def extract(_format, _source, _opts), do: {:error, :unsupported_format}
end
