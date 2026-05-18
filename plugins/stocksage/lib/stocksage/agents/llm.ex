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
    alias StockSage.Agents.CommitteeContext

    @schema %{
      type: "object",
      additionalProperties: false,
      properties: %{
        "summary" => %{type: "string"},
        "report" => %{type: "string"},
        "confidence" => %{type: "number"},
        "warnings" => %{type: "array", items: %{type: "string"}},
        "data_requests" => %{type: "array", items: %{type: "string"}},
        "final_trade_decision" => %{
          type: "string",
          enum: ["Buy", "Overweight", "Hold", "Underweight", "Sell"]
        },
        "rating" => %{
          type: "string",
          enum: ["Buy", "Overweight", "Hold", "Underweight", "Sell"]
        },
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
               max_tokens: 2_000,
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
      #{safe_json(request_summary(request))}

      Evidence summaries:
      #{safe_json(evidence_summary(evidence))}

      Prior reports:
      #{safe_json(prior_report_summary(prior_reports))}

      #{committee_context_section(spec, prior_reports)}

      Requirements:
      - Return only the requested structured object.
      - Do not claim to execute trades, contact brokers, or authorize actions.
      - Cite evidence uncertainty in warnings when useful.
      - Keep summary under 500 characters and report under 4000 characters.
      - For decision_synthesizer, include final_trade_decision on the
        Buy/Overweight/Hold/Underweight/Sell scale.
      """
    end

    defp request_summary(request) do
      %{
        ticker: field(request, :ticker),
        analysis_date: field(request, :analysis_date),
        stage: field(request, :stage),
        round_index: field(request, :round_index),
        evidence_mode: field(request, :evidence_mode)
      }
      |> drop_nil_values()
    end

    defp evidence_summary(evidence) when is_list(evidence) do
      evidence
      |> Enum.take(6)
      |> Enum.map(fn packet ->
        %{
          action: field(packet, :action),
          status: field(packet, :status),
          message: bounded_text(field(packet, :message), 500),
          evidence: prompt_value(field(packet, :evidence))
        }
        |> drop_nil_values()
      end)
    end

    defp evidence_summary(_evidence), do: []

    defp prior_report_summary(prior_reports) when is_map(prior_reports) do
      prior_reports
      |> CommitteeContext.ordered_reports()
      |> Enum.take(20)
      |> Map.new(fn {agent_id, report} ->
        {agent_id,
         %{
           status: field(report, :status),
           summary: bounded_text(field(report, :summary)),
           report: bounded_text(field(report, :report), 1_800),
           recommendation: field(report, :recommendation) || field(report, :final_trade_decision),
           confidence: field(report, :confidence),
           warnings: report |> field(:warnings, []) |> normalize_list() |> Enum.take(3)
         }
         |> drop_nil_values()}
      end)
    end

    defp prior_report_summary(_prior_reports), do: %{}

    defp committee_context_section(%{role: :decision_synthesizer}, prior_reports) do
      """
      Committee context:
      #{safe_json(CommitteeContext.summary(prior_reports))}
      """
    end

    defp committee_context_section(_spec, _prior_reports), do: ""

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
        _other -> 180_000
      end
    rescue
      _exception -> 180_000
    end

    defp field(map, key, default \\ nil)

    defp field(map, key, default) when is_map(map) do
      string_key = if is_atom(key), do: Atom.to_string(key), else: key
      atom_key = if is_binary(key), do: known_atom_key(key), else: key

      Map.get(map, key, Map.get(map, string_key, Map.get(map, atom_key, default)))
    end

    defp field(_map, _key, default), do: default

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

    defp prompt_value(nil), do: nil

    defp prompt_value(value) when is_map(value) do
      value
      |> AllbertSignals.redact()
      |> compact_prompt_value(0)
    end

    defp prompt_value(value), do: bounded_text(value, 1_200)

    defp compact_prompt_value(value, depth) when is_map(value) and depth < 5 do
      value
      |> Enum.take(40)
      |> Map.new(fn {key, nested} -> {key, compact_prompt_value(nested, depth + 1)} end)
    end

    defp compact_prompt_value(value, depth) when is_list(value) and depth < 5 do
      value
      |> Enum.take(10)
      |> Enum.map(&compact_prompt_value(&1, depth + 1))
    end

    defp compact_prompt_value(value, _depth) when is_binary(value), do: bounded_text(value, 3_500)

    defp compact_prompt_value(value, _depth)
         when is_number(value) or is_boolean(value) or is_nil(value),
         do: value

    defp compact_prompt_value(value, _depth) when is_atom(value), do: Atom.to_string(value)
    defp compact_prompt_value(value, _depth), do: bounded_text(value, 1_200)

    defp bounded_text(value, limit \\ 600)
    defp bounded_text(nil, _limit), do: nil

    defp bounded_text(value, limit) do
      value
      |> AllbertSignals.redact()
      |> inspect(limit: 12, printable_limit: limit)
      |> then(fn text ->
        if byte_size(text) > limit, do: binary_part(text, 0, limit), else: text
      end)
    end

    defp drop_nil_values(map) do
      Map.reject(map, fn {_key, value} -> is_nil(value) end)
    end

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
