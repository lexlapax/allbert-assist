defmodule AllbertAssist.Voice.TranscriptResponse do
  @moduledoc """
  Normalizes provider STT response bodies into transcript text.

  Provider adapters own request shape, but empty/missing transcript semantics
  should be consistent across local, OpenAI-compatible, and Gemini responses.
  """

  @type transcript_error :: :empty_voice_transcript | :missing_voice_transcript

  @spec transcript_text(term()) :: {:ok, String.t()} | {:error, transcript_error()}
  def transcript_text(body) do
    with {:ok, text} <- raw_text(body) do
      text
      |> String.trim()
      |> case do
        "" -> {:error, :empty_voice_transcript}
        transcript -> {:ok, transcript}
      end
    end
  end

  defp raw_text(text) when is_binary(text), do: {:ok, text}

  defp raw_text(%{} = body) do
    direct_text(body) || candidate_text(body) || segment_text(body) ||
      {:error, :missing_voice_transcript}
  end

  defp raw_text(values) when is_list(values) do
    values
    |> Enum.map(&raw_text/1)
    |> Enum.flat_map(fn
      {:ok, text} -> [text]
      {:error, _reason} -> []
    end)
    |> case do
      [] -> {:error, :missing_voice_transcript}
      texts -> {:ok, Enum.join(texts, "")}
    end
  end

  defp raw_text(_body), do: {:error, :missing_voice_transcript}

  defp direct_text(body) do
    [
      Map.get(body, "text"),
      Map.get(body, :text),
      Map.get(body, "transcript"),
      Map.get(body, :transcript),
      Map.get(body, "output_text"),
      Map.get(body, :output_text),
      Map.get(body, "outputText"),
      Map.get(body, :outputText)
    ]
    |> Enum.find_value(fn
      text when is_binary(text) -> {:ok, text}
      _value -> false
    end)
  end

  defp candidate_text(body) do
    body
    |> get_any(["candidates", :candidates])
    |> case do
      candidates when is_list(candidates) ->
        candidates
        |> Enum.flat_map(&candidate_parts/1)
        |> Enum.map(&(Map.get(&1, "text") || Map.get(&1, :text)))
        |> Enum.filter(&is_binary/1)
        |> case do
          [] -> nil
          texts -> {:ok, Enum.join(texts, "")}
        end

      _missing ->
        nil
    end
  end

  defp candidate_parts(candidate) when is_map(candidate) do
    candidate
    |> get_any(["content", :content])
    |> case do
      content when is_map(content) ->
        case get_any(content, ["parts", :parts]) do
          parts when is_list(parts) -> parts
          _missing -> []
        end

      _missing ->
        []
    end
  end

  defp candidate_parts(_candidate), do: []

  defp segment_text(body) do
    body
    |> get_any(["segments", :segments])
    |> case do
      segments when is_list(segments) ->
        segments
        |> Enum.map(fn
          segment when is_map(segment) -> Map.get(segment, "text") || Map.get(segment, :text)
          _segment -> nil
        end)
        |> Enum.filter(&is_binary/1)
        |> case do
          [] -> nil
          texts -> {:ok, Enum.join(texts, " ")}
        end

      _missing ->
        nil
    end
  end

  defp get_any(map, keys) when is_map(map) do
    Enum.find_value(keys, &Map.get(map, &1))
  end
end
