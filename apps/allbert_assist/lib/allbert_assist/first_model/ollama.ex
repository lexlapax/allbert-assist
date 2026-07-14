defmodule AllbertAssist.FirstModel.Ollama do
  @moduledoc """
  Ollama detection + the curated-default-model decision for the First-Model
  Path (v0.62 M4, ADR 0078: assisted-local default + BYOK fallback).

  Detection is a **three-way probe** (the M0/research finding that
  `brew install ollama` does not auto-start the server, so "installed but not
  running" is a real state):

    1. the `ollama` binary on `PATH`;
    2. the server answering `GET /api/version` on `127.0.0.1:11434`;
    3. the curated model present in `GET /api/tags`.

  All probe I/O is **localhost only** — no external egress in detection. The
  guided install and the model *pull* are separate, confirmation-gated actions
  (`InstallOllama`, `PullModel`) that carry the `:command_execute` /
  `:external_network` authority. The HTTP client is injectable for tests.
  """

  alias AllbertAssist.External.TLS

  @default_base_url "http://127.0.0.1:11434"
  @req_options_key :first_model_req_options

  # Curated default (Locked Decision 9): a ~3–4B model with an 8 GB floor.
  # Selected/refreshed in v0.62 per ADR 0078; ratified at S4. v1.0 M7.5 (R13):
  # these are the schema DEFAULTS for the `first_model.curated_model` /
  # `first_model.curated_floor_gb` Settings Central keys — operator-overridable
  # (`mix allbert.settings set first_model.curated_model <tag>`); the constants
  # remain only as the fallback when the settings store is not readable.
  @curated_model "llama3.2:3b"
  @curated_floor_gb 8

  @type probe_result :: :model_ready | :model_missing | :unhealthy | :missing

  @doc "The curated default model tag (settings-backed: `first_model.curated_model`)."
  @spec curated_model() :: String.t()
  def curated_model do
    case setting("first_model.curated_model") do
      model when is_binary(model) and model != "" -> model
      _other -> @curated_model
    end
  end

  @doc "The curated model's RAM floor in GB (settings-backed: `first_model.curated_floor_gb`)."
  def curated_floor_gb do
    case setting("first_model.curated_floor_gb") do
      floor when is_integer(floor) and floor > 0 -> floor
      _other -> @curated_floor_gb
    end
  end

  defp setting(key) do
    case AllbertAssist.Settings.get(key) do
      {:ok, value} -> value
      _other -> nil
    end
  rescue
    _error -> nil
  end

  @doc "The local Ollama base URL (settings-overridable elsewhere)."
  @spec base_url() :: String.t()
  def base_url do
    case normalize_host(System.get_env("OLLAMA_HOST")) do
      nil -> @default_base_url
      url -> url
    end
  end

  @doc "Return a loopback-only Ollama URL."
  @spec local_url(String.t()) :: {:ok, String.t()} | {:error, :non_loopback_host}
  def local_url(path) when is_binary(path) do
    url = base_url() <> path

    case URI.parse(url) do
      %URI{host: host} when host in ["127.0.0.1", "localhost", "::1"] -> {:ok, url}
      _other -> {:error, :non_loopback_host}
    end
  end

  @doc """
  Three-way probe → one of `:model_ready | :model_missing | :unhealthy |
  :missing`. `deps` injects `:binary?`, `:version`, and `:tags` for tests.
  """
  @spec probe(keyword()) :: probe_result()
  def probe(deps \\ []) do
    binary? = Keyword.get(deps, :binary?, &binary_present?/0)
    version = Keyword.get(deps, :version, &server_version/0)
    tags = Keyword.get(deps, :tags, &model_tags/0)
    model = Keyword.get(deps, :model, @curated_model)

    cond do
      not binary?.() and version.() == :error -> :missing
      version.() == :error -> :missing
      version.() == :unhealthy -> :unhealthy
      true -> if model in tags.(), do: :model_ready, else: :model_missing
    end
  end

  @doc "Is the `ollama` binary on PATH?"
  @spec binary_present?() :: boolean()
  def binary_present? do
    System.find_executable("ollama") != nil
  end

  @doc "Probe the local server version endpoint (localhost only)."
  @spec server_version() :: {:ok, String.t()} | :unhealthy | :error
  def server_version do
    case get("/api/version") do
      {:ok, %{"version" => v}} -> {:ok, v}
      {:ok, _other} -> :unhealthy
      :error -> :error
    end
  end

  @doc "List installed model tags (localhost only)."
  @spec model_tags() :: [String.t()]
  def model_tags do
    case get("/api/tags") do
      {:ok, %{"models" => models}} when is_list(models) ->
        Enum.map(models, &(&1["name"] || &1["model"]))

      _other ->
        []
    end
  end

  # -- localhost HTTP (injectable) -------------------------------------------

  defp get(path) do
    client = Application.get_env(:allbert_assist, :first_model_http, &default_get/1)

    case local_url(path) do
      {:ok, url} -> client.(url)
      {:error, _reason} -> :error
    end
  end

  defp default_get(url) do
    opts =
      [
        method: :get,
        url: url,
        receive_timeout: 1_500,
        retry: false,
        redirect: false
      ]
      # M8.2: CA trust for a custom HTTPS Ollama endpoint (harmless for the localhost
      # http default); the test-injected @req_options_key still overrides.
      |> Keyword.merge(TLS.connect_options())
      |> Keyword.merge(Application.get_env(:allbert_assist, @req_options_key, []))

    case Req.request(opts) do
      {:ok, %{status: 200, body: body}} ->
        decode_body(body)

      _other ->
        :error
    end
  end

  defp decode_body(body) when is_map(body), do: {:ok, body}

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      _error -> :error
    end
  end

  defp decode_body(_body), do: :error

  defp normalize_host(nil), do: nil
  defp normalize_host(""), do: nil
  defp normalize_host("http" <> _rest = url), do: url
  defp normalize_host(hostport), do: "http://" <> hostport
end
