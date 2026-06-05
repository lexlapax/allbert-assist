defmodule AllbertResearch.Research do
  @moduledoc false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Settings

  @default_extract_format "text"

  @spec run(atom(), map(), map()) :: {:ok, map()}
  def run(command, params, context)
      when command in [:research, :summarize_url] and is_map(params) do
    state = Map.get(context, :state, %{})

    result =
      case enabled?() do
        true -> run_enabled(command, params)
        false -> {:ok, disabled_response(command)}
      end

    {:ok, state_update(state, command, result)}
  end

  defp run_enabled(command, params) do
    case sources(params) do
      {:ok, sources} ->
        case ensure_session(command, params, sources) do
          {:ok, session_id, owned?} ->
            run_with_session(command, params, sources, session_id, owned?)

          {:pending, response} ->
            {:ok, response}

          {:error, response} ->
            {:ok, response}
        end

      {:error, response} ->
        {:ok, response}
    end
  end

  defp ensure_session(command, params, sources) do
    case field(params, :session_id) do
      session_id when is_binary(session_id) and session_id != "" ->
        {:ok, session_id, true}

      _other ->
        start_params = %{
          purpose: "#{command} via research.specialist",
          expected_domains: Enum.map(sources, &host/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
        }

        case Runner.run("browser_start_session", start_params, browser_context(params)) do
          {:ok, %{status: :completed, session_id: session_id}} ->
            {:ok, session_id, true}

          {:ok, %{status: :needs_confirmation} = response} ->
            {:pending, pending_response(command, :browser_start_session, response)}

          {:ok, response} ->
            {:error, failed_response(command, response)}
        end
    end
  end

  defp run_with_session(command, params, sources, session_id, owned?) do
    context = browser_context(params)

    case collect_sources(sources, session_id, context, extract_format(params), extract_cap()) do
      {:ok, collected} ->
        close_result = if owned?, do: close_session(session_id, context), else: :not_owned
        {:ok, completed_response(command, collected, close_result)}

      {:pending, response} ->
        {:ok, pending_response(command, :browser_navigate, response)}

      {:error, response} ->
        if owned?, do: close_session(session_id, context)
        {:ok, failed_response(command, response)}
    end
  end

  defp collect_sources(sources, session_id, context, extract_format, max_bytes) do
    Enum.reduce_while(sources, {:ok, []}, fn url, {:ok, collected} ->
      with {:ok, :navigated} <- navigate(session_id, url, context),
           {:ok, source} <- extract(session_id, url, extract_format, max_bytes, context) do
        {:cont, {:ok, [source | collected]}}
      else
        {:pending, response} -> {:halt, {:pending, response}}
        {:error, response} -> {:halt, {:error, response}}
      end
    end)
    |> case do
      {:ok, collected} -> {:ok, Enum.reverse(collected)}
      other -> other
    end
  end

  defp navigate(session_id, url, context) do
    case Runner.run("browser_navigate", %{session_id: session_id, url: url}, context) do
      {:ok, %{status: :completed}} -> {:ok, :navigated}
      {:ok, %{status: :needs_confirmation} = response} -> {:pending, response}
      {:ok, response} -> {:error, response}
    end
  end

  defp extract(session_id, url, format, max_bytes, context) do
    case Runner.run(
           "browser_extract",
           %{session_id: session_id, format: format, max_bytes: max_bytes},
           context
         ) do
      {:ok, %{status: :completed, extraction: extraction}} ->
        {:ok,
         %{
           url: url,
           title: title(extraction, url),
           extract_ref: Map.get(extraction, :cache_ref),
           bytes: Map.get(extraction, :bytes, 0),
           preview: preview(Map.get(extraction, :text, ""))
         }}

      {:ok, response} ->
        {:error, response}
    end
  end

  defp completed_response(command, sources, close_result) do
    summary = extractive_summary(sources)

    %{
      message: "Research #{command} completed.",
      status: :completed,
      summary: summary,
      output_data: %{
        summary: summary,
        sources: sources,
        notes: notes(close_result)
      },
      actions: [
        %{
          name: "research.specialist",
          status: :completed,
          advisory: true,
          command: command,
          source_count: length(sources)
        }
      ]
    }
  end

  defp pending_response(command, stage, response) do
    %{
      message: "Research #{command} is waiting for #{stage} confirmation.",
      status: :needs_confirmation,
      confirmation: Map.get(response, :confirmation),
      confirmation_id: Map.get(response, :confirmation_id),
      output_data: %{
        summary: nil,
        sources: [],
        notes: ["pending_confirmation=#{stage}", "advisory_only"]
      },
      actions: Map.get(response, :actions, [])
    }
  end

  defp failed_response(command, response) do
    %{
      message:
        "Research #{command} failed: #{inspect(Map.get(response, :error, response[:status]))}.",
      status: :error,
      error: Map.get(response, :error, :research_failed),
      output_data: %{
        summary: nil,
        sources: [],
        notes: ["failed", "advisory_only"]
      },
      actions: Map.get(response, :actions, [])
    }
  end

  defp disabled_response(command) do
    %{
      message: "Research #{command} is disabled.",
      status: :denied,
      error: :research_disabled,
      output_data: %{
        summary: nil,
        sources: [],
        notes: ["research.disabled", "advisory_only"]
      },
      actions: [
        %{
          name: "research.specialist",
          status: :denied,
          advisory: true,
          error: :research_disabled
        }
      ]
    }
  end

  defp close_session(session_id, context) do
    case Runner.run("browser_close_session", %{session_id: session_id}, context) do
      {:ok, %{status: :completed}} -> :closed
      {:ok, response} -> {:close_failed, Map.get(response, :error, Map.get(response, :status))}
    end
  end

  defp state_update(state, command, {:ok, response}) do
    Map.merge(state, %{
      agent_id: AllbertResearch.Runtime.agent_id(),
      last_command: command,
      last_result: {:ok, response},
      last_summary: Map.get(response, :summary) || Map.get(response, :message)
    })
  end

  defp sources(params) do
    params
    |> raw_sources()
    |> Enum.map(&normalize_url/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(max_sources(params))
    |> case do
      [] -> {:error, missing_source_response()}
      sources -> {:ok, sources}
    end
  end

  defp raw_sources(params) do
    cond do
      is_list(field(params, :sources)) ->
        field(params, :sources)

      is_list(field(params, :urls)) ->
        field(params, :urls)

      is_binary(field(params, :url)) ->
        [field(params, :url)]

      is_binary(field(params, :topic)) ->
        [field(params, :topic)]

      is_binary(field(params, :query)) ->
        [field(params, :query)]

      true ->
        []
    end
  end

  defp normalize_url(%{url: url}), do: normalize_url(url)
  defp normalize_url(%{"url" => url}), do: normalize_url(url)

  defp normalize_url(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        nil

      String.starts_with?(value, ["http://", "https://"]) ->
        value

      Regex.match?(~r/^[A-Za-z0-9.-]+\.[A-Za-z]{2,}([\/?#].*)?$/, value) ->
        "https://#{value}"

      true ->
        "https://example.com/search?q=#{URI.encode_www_form(value)}"
    end
  end

  defp normalize_url(_value), do: nil

  defp max_sources(params) do
    requested =
      case field(params, :max_sources) do
        value when is_integer(value) -> value
        value when is_binary(value) -> parse_integer(value)
        _other -> setting("research.max_sources", 3)
      end

    requested
    |> max(1)
    |> min(setting("research.max_sources", 3))
    |> min(8)
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> setting("research.max_sources", 3)
    end
  end

  defp extract_cap do
    min(
      setting("research.max_extract_bytes_per_source", 524_288),
      setting("browser.extraction.max_bytes", 1_048_576)
    )
  end

  defp extract_format(params), do: field(params, :extract_format, @default_extract_format)

  defp browser_context(params) do
    %{
      actor: field(params, :actor, "local"),
      user_id: field(params, :user_id, "local"),
      operator_id: field(params, :operator_id, field(params, :user_id, "local")),
      channel: field(params, :channel, :cli),
      surface: "research.delegate",
      objective_id: field(params, :objective_id),
      step_id: field(params, :step_id),
      app_id: :allbert_research
    }
  end

  defp extractive_summary([]), do: "No sources were extracted."

  defp extractive_summary(sources) do
    body =
      sources
      |> Enum.map(& &1.preview)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")
      |> normalize_space()
      |> String.slice(0, 600)

    "Research summary from #{length(sources)} source(s): #{body}"
  end

  defp notes(:closed),
    do: ["summary_engine=extractive_fallback", "session_closed", "advisory_only"]

  defp notes(:not_owned), do: ["summary_engine=extractive_fallback", "advisory_only"]
  defp notes({:close_failed, reason}), do: ["close_failed=#{inspect(reason)}", "advisory_only"]

  defp missing_source_response do
    %{
      message: "Research source is missing.",
      status: :error,
      error: :missing_research_source,
      output_data: %{summary: nil, sources: [], notes: ["missing_source", "advisory_only"]},
      actions: []
    }
  end

  defp enabled? do
    Settings.get("research.enabled") == {:ok, true}
  end

  defp setting(key, fallback) do
    case Settings.get(key) do
      {:ok, value} -> value
      _other -> fallback
    end
  end

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_map, _key, default), do: default

  defp host(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _other -> nil
    end
  end

  defp title(extraction, url), do: Map.get(extraction, :title) || host(url) || url

  defp preview(text) when is_binary(text) do
    text
    |> normalize_space()
    |> String.slice(0, 500)
  end

  defp preview(_text), do: ""

  defp normalize_space(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
