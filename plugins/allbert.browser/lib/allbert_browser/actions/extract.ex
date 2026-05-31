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
  alias AllbertBrowser.{Actions, Session}

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

      format not in [:html, :text] ->
        Actions.denied("browser_extract", :browser_extract, decision, :unsupported_format)

      true ->
        case Session.extract(session_id, format, max_bytes: max_bytes) do
          {:ok, extraction} ->
            completed(decision, session_id, extraction)

          {:error, reason} ->
            Actions.denied("browser_extract", :browser_extract, decision, reason)
        end
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
           format: extraction.format
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
