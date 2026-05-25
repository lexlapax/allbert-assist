defmodule AllbertAssist.DynamicPlugins.Codegen.LLM do
  @moduledoc """
  Injectable LLM boundary for source-bearing dynamic code generation.

  Production uses `Jido.AI.generate_object/3` so generation returns a
  schema-constrained object. Tests can inject a provider with the same
  `generate_action/4` contract, which keeps CI deterministic while preserving
  the real provider boundary.
  """

  alias AllbertAssist.DynamicPlugins.Codegen.CapabilityGap
  alias AllbertAssist.DynamicPlugins.Codegen.Schema
  alias AllbertAssist.Runtime.Redactor

  @callback generate_action(CapabilityGap.t(), map(), map(), map()) ::
              {:ok, map()} | {:error, term()}

  @doc "Generate one structured read-only action draft packet."
  @spec generate_action(CapabilityGap.t(), map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def generate_action(%CapabilityGap{} = gap, profile, budget, context)
      when is_map(profile) and is_map(budget) and is_map(context) do
    provider().generate_action(gap, profile, budget, context)
  end

  defp provider do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:provider, __MODULE__.JidoAI)
  end

  defmodule JidoAI do
    @moduledoc false

    alias AllbertAssist.DynamicPlugins.Codegen.CapabilityGap
    alias AllbertAssist.DynamicPlugins.Codegen.Schema
    alias AllbertAssist.Runtime.Redactor

    @spec generate_action(CapabilityGap.t(), map(), map(), map()) ::
            {:ok, map()} | {:error, term()}
    def generate_action(%CapabilityGap{} = gap, profile, budget, context) do
      with :ok <- ensure_jido_ai!(),
           {:ok, result} <-
             Jido.AI.generate_object(
               prompt(gap, budget, context),
               Schema.action_draft_schema(),
               [
                 model: model_option(profile),
                 system_prompt: system_prompt(),
                 max_tokens: Map.get(profile, :max_tokens) || 2_000,
                 temperature: Map.get(profile, :temperature) || 0.1,
                 timeout: Map.get(profile, :timeout_ms) || 30_000
               ]
               |> maybe_put_base_url(profile)
             ),
           {:ok, object} <- response_object(result) do
        {:ok, normalize_object(object, result)}
      else
        {:error, reason} -> {:error, reason}
      end
    rescue
      exception -> {:error, Exception.message(exception)}
    catch
      :exit, reason -> {:error, reason}
    end

    defp ensure_jido_ai! do
      if Code.ensure_loaded?(Jido.AI) do
        :ok
      else
        {:error, :jido_ai_unavailable}
      end
    end

    defp response_object(%ReqLLM.Response{} = response) do
      case ReqLLM.Response.object(response) do
        object when is_map(object) -> {:ok, object}
        nil -> {:error, :empty_dynamic_codegen_object}
      end
    end

    defp response_object(%{object: object}) when is_map(object), do: {:ok, object}
    defp response_object(%{"object" => object}) when is_map(object), do: {:ok, object}
    defp response_object(object) when is_map(object), do: {:ok, object}
    defp response_object(_other), do: {:error, :empty_dynamic_codegen_object}

    defp normalize_object(object, result) do
      object
      |> Map.take(["action_name", "description", "source", "test_source", "notes", "usage_units"])
      |> Map.put_new("notes", [])
      |> Map.put_new("usage", response_usage(result))
      |> Redactor.redact()
    end

    defp response_usage(%ReqLLM.Response{} = response), do: ReqLLM.Response.usage(response) || %{}
    defp response_usage(%{usage: usage}) when is_map(usage), do: usage
    defp response_usage(%{"usage" => usage}) when is_map(usage), do: usage
    defp response_usage(_result), do: %{}

    defp model_option(%{model: model, provider_type: provider_type})
         when is_binary(model) and model != "" do
      model_spec(provider_type, model)
    end

    defp model_option(%{name: name}) when is_binary(name), do: model_alias_or_spec(name)
    defp model_option(%{model: model}) when is_binary(model), do: model
    defp model_option(_profile), do: :fast

    defp model_spec(provider_type, model) do
      cond do
        provider_prefixed?(model) ->
          model

        provider = req_llm_provider(provider_type) ->
          "#{provider}:#{model}"

        true ->
          model
      end
    end

    defp provider_prefixed?(model) do
      case String.split(model, ":", parts: 2) do
        [provider, _model] ->
          provider in ~w[anthropic openai openai_codex openrouter google mistral]

        _other ->
          false
      end
    end

    defp req_llm_provider("openai"), do: "openai"
    defp req_llm_provider("openai_compatible"), do: "openai"
    defp req_llm_provider("local"), do: "openai"
    defp req_llm_provider("anthropic"), do: "anthropic"
    defp req_llm_provider(_provider_type), do: nil

    defp model_alias_or_spec("fast"), do: :fast
    defp model_alias_or_spec("capable"), do: :capable
    defp model_alias_or_spec("slow"), do: :slow
    defp model_alias_or_spec("thinking"), do: :thinking
    defp model_alias_or_spec("gpt"), do: :gpt
    defp model_alias_or_spec("local"), do: :local
    defp model_alias_or_spec(name), do: name

    defp maybe_put_base_url(opts, %{provider_type: "openai", provider_base_url: nil}) do
      Keyword.put(opts, :base_url, "https://api.openai.com/v1")
    end

    defp maybe_put_base_url(opts, %{provider_base_url: base_url})
         when is_binary(base_url) and base_url != "" do
      Keyword.put(opts, :base_url, base_url)
    end

    defp maybe_put_base_url(opts, _profile), do: opts

    defp system_prompt do
      """
      You generate one Allbert dynamic read-only action draft.

      Return only the requested structured object. The source and test_source
      must be complete Elixir files. Use placeholders {{MODULE}},
      {{TEST_MODULE}}, and {{ACTION_NAME}} instead of hard-coded module/action
      names. The action must use AllbertAssist.Action with permission
      :read_only, exposure :internal, execution_mode :read_only,
      skill_backed?: false, confirmation :not_required, and output
      %{message: string, status: :completed, actions: []}. Do not use System,
      File, Code, Mix, Application, Process, Port, Node, Repo, Settings,
      confirmations, resources, network calls, dependencies, macros, @on_load,
      or dynamic atoms.
      """
    end

    defp prompt(%CapabilityGap{} = gap, budget, context) do
      """
      Create a useful read-only Allbert action draft for this explicit
      capability gap.

      Gap:
      #{Jason.encode!(CapabilityGap.summary(gap))}

      Budget:
      #{Jason.encode!(Map.take(budget, ["provider_calls_budget", "provider_usage_units_budget"]))}

      Request context:
      #{Jason.encode!(Redactor.redact(Map.take(context, [:actor, :channel, :surface])))}

      Requirements:
      - Generate normal pure Elixir logic. It may format strings, do
        arithmetic/comparison, and iterate lists.
      - The action body must be deterministic and read-only.
      - Include one focused ExUnit test that calls {{MODULE}}.run/2 directly.
      - Keep source under 160 lines and test_source under 120 lines.
      """
    end
  end
end
