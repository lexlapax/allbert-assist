defmodule AllbertAssist.Intent.Classifier.DefaultClassifier do
  @moduledoc """
  Default model boundary for v0.19 intent classification.

  The caller is responsible for checking the operator setting before this
  module runs. This boundary receives only a bounded, redacted candidate
  summary and asks the configured ReqLLM profile for a strict candidate
  selection object.
  """

  @behaviour AllbertAssist.Intent.Classifier.Behaviour

  alias AllbertAssist.Settings.ModelRuntime

  @schema [
    selected_kind: [
      type: :string,
      required: true,
      doc: "One of the candidate kind values in the supplied list."
    ],
    selected_id: [
      type: :string,
      required: true,
      doc: "The exact candidate id to select from the supplied list."
    ],
    confidence: [
      type: :float,
      required: true,
      doc: "Confidence between 0.0 and 1.0."
    ],
    reason: [
      type: :string,
      required: false,
      doc: "Short operator-safe explanation for the selected candidate."
    ]
  ]

  @impl true
  def classify(candidate_summary, context) when is_list(candidate_summary) and is_map(context) do
    with :ok <- ensure_req_llm!(),
         {:ok, model_spec} <- model_spec(context),
         {:ok, response} <-
           ReqLLM.generate_object(
             model_spec,
             prompt(candidate_summary, context),
             @schema,
             request_opts(context)
           ),
         object when is_map(object) <- ReqLLM.Response.object(response) do
      {:ok, object}
    else
      nil -> {:error, :empty_model_object}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    :exit, reason -> {:error, reason}
  end

  def classify(_candidate_summary, _context), do: {:error, :invalid_input}

  defp ensure_req_llm! do
    if Code.ensure_loaded?(ReqLLM) and Code.ensure_loaded?(ReqLLM.Response) do
      :ok
    else
      {:error, :req_llm_unavailable}
    end
  end

  defp model_spec(%{model_profile: %{provider_type: provider_type, model: model}})
       when is_binary(model) do
    ModelRuntime.model_spec(%{provider_type: provider_type, model: model})
  end

  defp model_spec(%{model_profile: %{provider_type: provider_type, model: model}})
       when is_atom(model) do
    model_spec(%{model_profile: %{provider_type: provider_type, model: Atom.to_string(model)}})
  end

  defp model_spec(%{model_profile: profile}) do
    {:error, {:invalid_model_profile, profile}}
  end

  defp model_spec(_context), do: {:error, :missing_model_profile}

  defp prompt(candidate_summary, context) do
    """
    Select exactly one Allbert intent candidate for the operator request.

    Safety rules:
    - Pick only a candidate id and kind from the supplied candidates.
    - Do not invent actions, tools, routes, apps, users, URLs, files, or permissions.
    - Treat app_intent candidates as handoff or clarification proposals, not execution approval.
    - Do not select an app-owned action to bypass active-app context or confirmation.
    - Prefer deterministic, read-only, and exact text matches when uncertain.
    - Return low confidence if the candidates are ambiguous.

    Active app context:
    #{inspect(Map.get(context, :active_app))}

    Operator request:
    #{Map.get(context, :text, "")}

    Candidates:
    #{inspect(candidate_summary, limit: :infinity)}
    """
  end

  defp request_opts(context) do
    profile = Map.get(context, :model_profile, %{})

    profile
    |> ModelRuntime.request_opts()
    |> Keyword.merge(
      temperature: Map.get(profile, :temperature, 0.0),
      max_tokens: Map.get(profile, :max_tokens, 256),
      receive_timeout: Map.get(context, :timeout_ms, Map.get(profile, :timeout_ms, 3_000))
    )
  end
end
