defmodule AllbertBrowser.Actions.Extract do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :browser_extract,
    exposure: :internal,
    execution_mode: :browser_session,
    skill_backed?: false,
    confirmation: :not_required,
    plugin_id: "allbert.browser",
    name: "browser_extract",
    description: "Extract bounded text from an already-loaded browser page.",
    category: "browser",
    tags: ["browser", "extract", "read_only"],
    schema: [
      session_id: [type: :string, required: true],
      format: [type: :string, required: true],
      max_bytes: [type: :integer, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Settings
  alias AllbertBrowser.{Actions, Cache, Extractors, Session}

  @impl true
  def run(params, context) do
    decision = Actions.authorize(:browser_extract, context)
    session_id = Actions.field(params, :session_id)
    format = format(Actions.field(params, :format, "text"))

    max_bytes =
      Actions.field(params, :max_bytes) || elem(Settings.get("browser.extraction.max_bytes"), 1)

    cond do
      not Actions.allowed?(decision) ->
        Actions.denied("browser_extract", :browser_extract, decision, :permission_denied)

      session_id in [nil, ""] ->
        Actions.denied("browser_extract", :browser_extract, decision, :missing_session_id)

      format not in [:html, :text, :markdown, :pdf] ->
        Actions.denied("browser_extract", :browser_extract, decision, :unsupported_format)

      true ->
        extraction_opts = extraction_opts(format, max_bytes)

        with {:ok, source} <- Session.extract(session_id, source_format(format), extraction_opts),
             {:ok, extraction} <- extract(format, source, extraction_opts),
             {:ok, artifact} <- cache_extraction(session_id, extraction) do
          completed(decision, session_id, Map.put(extraction, :cache_ref, artifact.ref))
        else
          {:error, reason} ->
            Actions.denied("browser_extract", :browser_extract, decision, reason)
        end
    end
  end

  defp extraction_opts(format, max_bytes) do
    [
      max_bytes: max_bytes,
      pdf_max_pages: setting("browser.extraction.pdf_max_pages", 50),
      pdf_parse_timeout_ms: setting("browser.extraction.pdf_parse_timeout_ms", 20_000),
      requested_format: format
    ]
  end

  defp source_format(:markdown), do: :html
  defp source_format(format), do: format

  defp extract(format, source, opts) do
    source = Map.get(source, :content) || Map.get(source, :text) || ""
    Extractors.extract(format, source, opts)
  end

  defp cache_extraction(session_id, extraction) do
    Cache.put(session_id, "extraction", extraction.text,
      ext: extension(extraction.format),
      metadata: %{
        format: Atom.to_string(extraction.format),
        preview: String.slice(extraction.text, 0, 512)
      }
    )
  end

  defp extension(:html), do: ".html"
  defp extension(:markdown), do: ".md"
  defp extension(:pdf), do: ".txt"
  defp extension(:text), do: ".txt"

  defp setting(key, fallback) do
    case Settings.get(key) do
      {:ok, value} -> value
      {:error, _reason} -> fallback
    end
  end

  defp completed(decision, session_id, extraction) do
    {:ok,
     %{
       message: "Browser extraction completed.",
       status: :completed,
       session_id: session_id,
       extraction: extraction,
       permission_decision: decision,
       actions: [
         Actions.action("browser_extract", :completed, :browser_extract, decision, %{
           session_id: session_id,
           bytes: extraction.bytes,
           format: extraction.format,
           cache_ref: Map.get(extraction, :cache_ref)
         })
       ]
     }}
  end

  defp format(value) when is_atom(value), do: value

  defp format(value) when is_binary(value) do
    value |> String.downcase() |> String.to_existing_atom()
  rescue
    ArgumentError -> :unsupported
  end

  defp format(_value), do: :text
end
