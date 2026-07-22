defmodule AllbertAssist.Intent.Decomposer.ReqLLMProposer do
  @moduledoc """
  Settings-owned ReqLLM structured-output boundary for Stage-0 proposals.

  Model output is advisory and bounded again by `Intent.Decomposer`; failures
  always degrade to the existing single-turn pipeline.
  """

  alias AllbertAssist.Maps
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.ModelRuntime

  @schema [
    decision: [type: :string, required: true, doc: "fanout or single"],
    tasks_json: [
      type: :string,
      required: true,
      doc: "A JSON array of independent task strings; [] for single."
    ]
  ]

  @spec propose(String.t(), map()) :: {:ok, [String.t()]} | {:error, term()}
  def propose(text, context) do
    with :ok <- ensure_req_llm(),
         {:ok, profile} <- profile(context),
         {:ok, spec} <- ModelRuntime.model_spec(profile),
         {:ok, response} <-
           ReqLLM.generate_object(spec, prompt(text), @schema, request_opts(profile, context)),
         object when is_map(object) <- ReqLLM.Response.object(response),
         "fanout" <- Maps.field_truthy(object, :decision),
         {:ok, tasks} when is_list(tasks) <- decode_tasks(Maps.field_truthy(object, :tasks_json)) do
      {:ok, tasks}
    else
      "single" -> {:ok, []}
      nil -> {:error, :empty_model_object}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_decomposition}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp profile(%{model_profile: profile}) when is_map(profile), do: {:ok, profile}

  defp profile(_context) do
    with {:ok, name} when is_binary(name) <- Settings.get("intent.router_model_profile") do
      Settings.resolve_model_profile(name)
    end
  end

  defp request_opts(profile, context) do
    profile
    |> ModelRuntime.request_opts()
    |> Keyword.merge(
      temperature: 0.0,
      max_tokens: ModelRuntime.max_tokens(profile, 512),
      receive_timeout: Map.get(context, :timeout_ms, 4_000),
      openai_structured_output_mode: :json_schema
    )
  end

  defp prompt(text) do
    """
    Decide whether the operator request contains at least two independent tasks
    that can make progress concurrently.

    Return decision=fanout only when each task is useful on its own. Preserve
    every requested task exactly once. Dependencies, one combined outcome,
    uncertainty, status/cancel/steering, and requests not to split are single.
    tasks_json must be a JSON array of concise task strings, or [] for single.

    Operator request:
    #{text}
    """
  end

  defp decode_tasks(value) when is_binary(value), do: Jason.decode(value)
  defp decode_tasks(_value), do: {:error, :invalid_tasks_json}

  defp ensure_req_llm do
    if Code.ensure_loaded?(ReqLLM) and Code.ensure_loaded?(ReqLLM.Response),
      do: :ok,
      else: {:error, :req_llm_unavailable}
  end
end
