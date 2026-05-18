defmodule StockSage.Agents.LLM do
  @moduledoc """
  Bounded Jido.AI generation boundary for StockSage native specialists.

  This module keeps provider-backed reasoning explicit and injectable. Tests
  can replace the provider without spending tokens, while production uses the
  `Jido.AI.generate_object/3` facade configured through `:jido_ai` model
  aliases and ReqLLM provider credentials.
  """

  alias AllbertAssist.Settings
  @spec enabled?() :: boolean()
  def enabled? do
    case Keyword.fetch(config(), :enabled?) do
      {:ok, value} ->
        value in [true, "true", "1"]

      :error ->
        case Settings.get("stocksage.native_llm_enabled") do
          {:ok, value} -> value in [true, "true", "1"]
          _other -> true
        end
    end
  rescue
    _exception -> true
  end

  @spec generate_report(map(), map(), [map()], map(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def generate_report(spec, request, evidence, prior_reports, model_profile) do
    provider().generate_report(spec, request, evidence, prior_reports, model_profile)
  end

  defp provider do
    Keyword.get(config(), :provider, __MODULE__.JidoAI)
  end

  defp config, do: Application.get_env(:allbert_assist, __MODULE__, [])

  defmodule JidoAI do
    @moduledoc false

    alias AllbertAssist.Settings
    alias AllbertAssist.Signals, as: AllbertSignals
    alias StockSage.Agents

    @schema %{
      type: "object",
      properties: %{
        "summary" => %{type: "string"},
        "report" => %{type: "string"},
        "confidence" => %{type: "number"},
        "warnings" => %{type: "array", items: %{type: "string"}},
        "data_requests" => %{type: "array", items: %{type: "object"}},
        "final_trade_decision" => %{
          type: "string",
          enum: ["Buy", "Overweight", "Hold", "Underweight", "Sell"]
        },
        "rating" => %{type: "string"},
        "recommendation" => %{type: "string"},
        "investment_plan" => %{type: "string"},
        "trader_investment_plan" => %{type: "string"},
        "market_report" => %{type: "string"},
        "sentiment_report" => %{type: "string"},
        "news_report" => %{type: "string"},
        "fundamentals_report" => %{type: "string"}
      },
      required: ["summary", "report", "confidence"]
    }

    @spec generate_report(map(), map(), [map()], map(), String.t() | nil) ::
            {:ok, map()} | {:error, term()}
    def generate_report(spec, request, evidence, prior_reports, model_profile) do
      with :ok <- ensure_jido_ai!(),
           {:ok, response} <-
             Jido.AI.generate_object(
               prompt(spec, request, evidence, prior_reports),
               @schema,
               model: model_option(model_profile),
               system_prompt: prompt_file(spec),
               max_tokens: 1_200,
               temperature: 0.2,
               timeout: timeout_ms()
             ),
           {:ok, object} <- response_object(response) do
        {:ok, normalize_object(object)}
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
        nil -> {:error, :empty_llm_object}
      end
    end

    defp normalize_object(object) do
      %{
        summary: field(object, "summary"),
        report: field(object, "report"),
        confidence: normalize_confidence(field(object, "confidence")),
        warnings: normalize_list(field(object, "warnings")),
        data_requests: normalize_list(field(object, "data_requests")),
        generation_mode: "jido_ai_llm",
        extra:
          object
          |> Map.take([
            "final_trade_decision",
            "rating",
            "recommendation",
            "investment_plan",
            "trader_investment_plan",
            "market_report",
            "sentiment_report",
            "news_report",
            "fundamentals_report"
          ])
          |> atomize_keys()
      }
    end

    defp prompt(spec, request, evidence, prior_reports) do
      """
      Produce one bounded StockSage advisory report packet.

      Agent:
      #{inspect(Map.take(spec, [:id, :role, :prompt_version]), pretty: true)}

      Request:
      #{safe_json(request)}

      Evidence summaries:
      #{safe_json(evidence)}

      Prior reports:
      #{safe_json(prior_reports)}

      Requirements:
      - Return only the requested structured object.
      - Do not claim to execute trades, contact brokers, or authorize actions.
      - Cite evidence uncertainty in warnings when useful.
      - Keep summary under 500 characters and report under 4000 characters.
      - For decision_synthesizer, include final_trade_decision on the
        Buy/Overweight/Hold/Underweight/Sell scale.
      """
    end

    defp prompt_file(spec) do
      spec
      |> Agents.prompt_path()
      |> File.read!()
    end

    defp safe_json(value) do
      value
      |> AllbertSignals.redact()
      |> Jason.encode!(pretty: true)
    rescue
      _exception -> inspect(AllbertSignals.redact(value), limit: 20, printable_limit: 2_000)
    end

    defp model_option("fast"), do: :fast
    defp model_option("slow"), do: :slow
    defp model_option(value) when is_atom(value), do: value
    defp model_option(value) when is_binary(value), do: value
    defp model_option(_value), do: :fast

    defp timeout_ms do
      case Settings.get("stocksage.native_agent_timeout_ms") do
        {:ok, value} when is_integer(value) and value > 0 -> value
        _other -> 90_000
      end
    rescue
      _exception -> 90_000
    end

    defp field(map, key), do: Map.get(map, key, Map.get(map, known_atom_key(key)))

    defp normalize_confidence(value) when is_float(value), do: max(0.0, min(1.0, value))
    defp normalize_confidence(value) when is_integer(value), do: normalize_confidence(value / 1)

    defp normalize_confidence(value) when is_binary(value) do
      case Float.parse(value) do
        {parsed, _rest} -> normalize_confidence(parsed)
        :error -> 0.5
      end
    end

    defp normalize_confidence(_value), do: 0.5

    defp normalize_list(value) when is_list(value), do: value
    defp normalize_list(nil), do: []
    defp normalize_list(value), do: [value]

    defp atomize_keys(map) do
      map
      |> Enum.flat_map(fn
        {key, value} when is_binary(key) ->
          case known_atom_key(key) do
            nil -> []
            atom_key -> [{atom_key, value}]
          end

        pair ->
          [pair]
      end)
      |> Map.new()
    end

    defp known_atom_key("summary"), do: :summary
    defp known_atom_key("report"), do: :report
    defp known_atom_key("confidence"), do: :confidence
    defp known_atom_key("warnings"), do: :warnings
    defp known_atom_key("data_requests"), do: :data_requests
    defp known_atom_key("final_trade_decision"), do: :final_trade_decision
    defp known_atom_key("rating"), do: :rating
    defp known_atom_key("recommendation"), do: :recommendation
    defp known_atom_key("investment_plan"), do: :investment_plan
    defp known_atom_key("trader_investment_plan"), do: :trader_investment_plan
    defp known_atom_key("market_report"), do: :market_report
    defp known_atom_key("sentiment_report"), do: :sentiment_report
    defp known_atom_key("news_report"), do: :news_report
    defp known_atom_key("fundamentals_report"), do: :fundamentals_report
    defp known_atom_key(_key), do: nil
  end
end
