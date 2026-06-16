defmodule AllbertAssist.Intent.Router.Doctor do
  @moduledoc """
  Redacted readiness doctor for the intent router (ADR 0047 envelope, ADR 0061).

  Probes the local embedder, and reports the configured router strategy,
  profiles, and utterance-index state. Never prints secrets. Surfaced via
  `mix allbert.intent doctor`.
  """
  alias AllbertAssist.Intent.Router
  alias AllbertAssist.Intent.Router.Embedder
  alias AllbertAssist.Intent.Router.Index
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  @state_path Path.join(["intent", "router", "doctor", "state.json"])

  @spec diagnose(keyword()) :: {:ok, map()}
  def diagnose(opts \\ []) do
    result = run_checks(opts)
    :ok = write_state(result)
    {:ok, result}
  end

  def read_state do
    path = state_path()

    with true <- File.regular?(path),
         {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    else
      _other -> {:error, :not_found}
    end
  end

  def state_path, do: Path.join(Paths.cache_root(), @state_path)

  defp run_checks(opts) do
    {embed_status, embed_dim} = probe_embedder(opts)
    index = index_state()

    %{
      status: doctor_status(embed_status),
      strategy: Router.strategy(),
      embedding_profile: setting("intent.router_embedding_profile"),
      model_profile: setting("intent.router_model_profile"),
      escalation_profile: escalation_label(setting("intent.router_escalation_profile")),
      embedding_endpoint: embed_status,
      embedding_dim: embed_dim,
      index_status: index.status,
      index_size: length(index.entries),
      index_built_at: index.built_at && DateTime.to_iso8601(index.built_at),
      checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp probe_embedder(opts) do
    case Embedder.embed(["allbert intent router doctor probe"], opts) do
      {:ok, [vector | _]} when is_list(vector) -> {:available, length(vector)}
      {:ok, _other} -> {:unavailable, nil}
      {:error, _reason} -> {:unavailable, nil}
    end
  end

  defp index_state do
    case Process.whereis(Index) do
      nil -> %Index{status: :not_started}
      _pid -> Index.state()
    end
  catch
    :exit, _reason -> %Index{status: :unavailable}
  end

  defp doctor_status(:available), do: :ok
  defp doctor_status(_other), do: :unavailable

  defp escalation_label(value) when value in [nil, ""], do: "disabled"
  defp escalation_label(value), do: value

  defp setting(key) do
    case Settings.get(key) do
      {:ok, value} -> value
      _other -> nil
    end
  end

  defp write_state(result) do
    path = state_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(stringify(result), pretty: true))
    :ok
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value) when is_boolean(value), do: value
  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value
end
