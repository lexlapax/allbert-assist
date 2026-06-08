defmodule AllbertBrowser.Actions.AnalyzeScreenshot do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :image_input,
    exposure: :internal,
    execution_mode: :read_only,
    skill_backed?: false,
    confirmation: :not_required,
    plugin_id: "allbert.browser",
    name: "analyze_browser_screenshot",
    description:
      "Analyze an existing browser screenshot cache ref through the vision input path.",
    category: "browser",
    tags: ["browser", "screenshot", "vision", "read_only"],
    schema: [
      screenshot_ref: [type: :string, required: true],
      text: [type: :string, required: true]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Resources.ResourceURI
  alias AllbertBrowser.{Actions, Cache}

  @impl true
  def run(params, context) do
    decision = Actions.authorize(:image_input, context)

    with true <- Actions.allowed?(decision),
         {:ok, text} <- text(params),
         {:ok, artifact} <- Cache.fetch(Actions.field(params, :screenshot_ref)),
         {:ok, image_input} <- image_input(artifact),
         {:ok, response} <-
           Runner.run("direct_answer", %{text: text}, vision_context(context, image_input)) do
      {:ok, completed(decision, artifact, response)}
    else
      false ->
        Actions.denied("analyze_browser_screenshot", :image_input, decision, :permission_denied)

      {:error, reason} ->
        Actions.denied("analyze_browser_screenshot", :image_input, decision, reason)
    end
  end

  defp text(params) do
    params
    |> Actions.field(:text)
    |> case do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, :missing_text}, else: {:ok, value}

      _value ->
        {:error, :missing_text}
    end
  end

  defp image_input(%{path: path, ref: ref} = artifact) when is_binary(path) and is_binary(ref) do
    with {:ok, resource_uri} <- ResourceURI.screen_capture(capture_id(artifact)) do
      {:ok,
       %{
         path: path,
         resource_uri: resource_uri,
         filename: Path.basename(path),
         transient?: false,
         source: :browser_screenshot,
         origin_kind: :browser_screenshot,
         screenshot_ref: ref,
         redacted_credential_inputs?: Map.get(artifact, :redacted_credential_inputs?)
       }}
    end
  end

  defp image_input(_artifact), do: {:error, :invalid_browser_screenshot_artifact}

  defp capture_id(%{sha256: sha256}) when is_binary(sha256), do: "browser_" <> sha256

  defp capture_id(%{path: path}) when is_binary(path),
    do: "browser_" <> Path.rootname(Path.basename(path))

  defp vision_context(context, image_input) do
    metadata =
      context
      |> request_metadata()
      |> Map.put(:image_inputs, [image_input])

    Map.update(context, :request, %{metadata: metadata}, fn
      request when is_map(request) -> Map.put(request, :metadata, metadata)
      _request -> %{metadata: metadata}
    end)
  end

  defp request_metadata(context) do
    get_in(context, [:request, :metadata]) ||
      get_in(context, ["request", "metadata"]) ||
      Map.get(context, :metadata) ||
      Map.get(context, "metadata") ||
      %{}
  end

  defp completed(decision, artifact, response) do
    screenshot_ref = Map.get(artifact, :ref)
    image_inputs = get_in(response, [:direct_answer, :media, :image_inputs]) || []

    response
    |> Map.put(:message, Map.get(response, :message, "Browser screenshot analyzed."))
    |> Map.put(:permission_decision, decision)
    |> Map.put(:browser_screenshot, %{
      screenshot_ref: screenshot_ref,
      redacted_credential_inputs?: Map.get(artifact, :redacted_credential_inputs?),
      image_inputs: image_inputs
    })
    |> Map.update(:actions, [], fn actions ->
      [
        Actions.action("analyze_browser_screenshot", :completed, :image_input, decision, %{
          screenshot_ref: screenshot_ref,
          image_inputs: image_inputs,
          direct_answer_status: Map.get(response, :status)
        })
        | actions
      ]
    end)
  end
end
