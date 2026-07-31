defmodule AllbertAssist.Intent.Classifier.DefaultClassifier do
  @moduledoc """
  Default model boundary for v0.19 intent classification.

  The caller is responsible for checking the operator setting before this
  module runs. This boundary receives only a bounded, redacted candidate
  summary and asks the configured ReqLLM profile for a strict candidate
  selection object.
  """

  @behaviour AllbertAssist.Intent.Classifier.Behaviour

  alias AllbertAssist.Models.PromptEnvelope
  alias AllbertAssist.Settings.ModelRuntime

  @prompt_rules [
    known_candidate_only: "Pick only an id and kind from the supplied candidate set.",
    no_invention:
      "Do not invent actions, tools, routes, apps, users, URLs, files, permissions, or candidate data.",
    app_intent_is_proposal:
      "Treat app-intent candidates as handoff or clarification proposals, never execution approval.",
    preserve_authority:
      "Do not use an app-owned action to bypass active-app context, confirmation, Registry, Runner, or Security Central.",
    deterministic_preference:
      "Prefer deterministic, read-only, exact-text candidates when evidence is otherwise equal.",
    honest_uncertainty: "Return low confidence when the supplied candidates are ambiguous."
  ]

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
         {:ok, prompt_context} <- prompt_context(candidate_summary, context),
         {:ok, response} <-
           ReqLLM.generate_object(
             model_spec,
             prompt_context,
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

  @doc false
  @spec prompt_context([map()], map()) :: {:ok, ReqLLM.Context.t()} | {:error, term()}
  def prompt_context(candidate_summary, context)
      when is_list(candidate_summary) and is_map(context) do
    PromptEnvelope.build(
      purpose: :intent_classification,
      instruction: "Select exactly one Allbert intent candidate for the operator request.",
      rules: @prompt_rules,
      reference_context: """
      Active app context:
      #{inspect(Map.get(context, :active_app))}

      Candidate data:
      #{inspect(candidate_summary, limit: :infinity)}
      """,
      input: Map.get(context, :text, "")
    )
  end

  def prompt_context(_candidate_summary, _context), do: {:error, :invalid_classifier_prompt}

  defp request_opts(context) do
    profile = Map.get(context, :model_profile, %{})

    profile
    |> ModelRuntime.request_opts()
    |> Keyword.merge(
      temperature: Map.get(profile, :temperature, 0.0),
      max_tokens: ModelRuntime.max_tokens(profile, 256),
      receive_timeout: Map.get(context, :timeout_ms, Map.get(profile, :timeout_ms, 3_000))
    )
  end
end
