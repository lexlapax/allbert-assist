defmodule AllbertAssist.Models.Catalog do
  @moduledoc """
  Read-only, no-hosted-egress model catalog assembled from shipped metadata,
  localhost runtime inventory, configured profiles, and bounded LLMDB metadata.
  """

  alias AllbertAssist.FirstModel.Ollama
  alias AllbertAssist.Settings

  @catalog_path "model_catalog.json"
  @spec list(keyword()) ::
          {:ok, %{version: pos_integer(), entries: [map()], diagnostics: [map()]}}
  def list(opts \\ []) do
    {shipped, diagnostics} = shipped_catalog(opts)
    pulled = Keyword.get_lazy(opts, :pulled_models, &Ollama.model_tags/0)
    profiles = Keyword.get_lazy(opts, :profiles, &configured_profiles/0)

    entries =
      shipped
      |> annotate_pulled(pulled)
      |> merge_runtime(pulled)
      |> merge_profiles(profiles, pulled)
      |> Enum.sort_by(&sort_key/1)

    {:ok, %{version: 1, entries: entries, diagnostics: diagnostics}}
  end

  defp shipped_catalog(opts) do
    path =
      Keyword.get(
        opts,
        :catalog_path,
        Application.app_dir(:allbert_assist, "priv/#{@catalog_path}")
      )

    with {:ok, bytes} <- File.read(path),
         {:ok, %{"local" => local, "hosted" => hosted}} <- Jason.decode(bytes) do
      {Enum.map(local ++ hosted, &normalize_shipped/1), []}
    else
      _error -> {[], [%{code: :curated_catalog_unavailable, source: :curated}]}
    end
  end

  defp normalize_shipped(row) do
    values =
      for key <-
            ~w(id provider model label size_bytes floor_gb capabilities purposes license thinking),
          into: %{},
          do: {String.to_existing_atom(key), Map.get(row, key)}

    Map.merge(values, %{
      source: if(values.provider == "ollama", do: :curated, else: :hosted_metadata),
      pulled?: false,
      configured?: false,
      status: :available
    })
  end

  defp annotate_pulled(rows, pulled) do
    Enum.map(rows, fn row ->
      if row.provider == "ollama" and row.model in pulled,
        do: %{row | pulled?: true, status: :ready},
        else: row
    end)
  end

  defp merge_runtime(rows, pulled) do
    known = MapSet.new(Enum.map(rows, & &1.model))

    rows ++
      for model <- pulled, not MapSet.member?(known, model) do
        %{
          id: "ollama:#{model}",
          provider: "ollama",
          model: model,
          label: model,
          capabilities: ["text"],
          purposes: ["configured"],
          source: :runtime,
          pulled?: true,
          configured?: false,
          status: :ready,
          floor_gb: nil,
          size_bytes: nil,
          license: "unknown",
          thinking: false
        }
      end
  end

  defp merge_profiles(rows, profiles, pulled) do
    rows ++
      Enum.map(profiles, fn profile ->
        %{
          id: "profile:#{profile.name}",
          profile: profile.name,
          provider: to_string(profile.provider),
          model: profile.model,
          label: profile.name,
          capabilities: Enum.map(profile.capabilities, &to_string/1),
          purposes: ["configured"],
          source: :configured,
          pulled?: to_string(profile.provider) == "ollama" and profile.model in pulled,
          configured?: true,
          status: :configured,
          floor_gb: nil,
          size_bytes: nil,
          license: "provider/model terms",
          thinking: false
        }
      end)
  end

  defp configured_profiles do
    case Settings.list_model_profiles() do
      {:ok, profiles} -> profiles
      _error -> []
    end
  end

  defp sort_key(row), do: {if(row.source == :curated, do: 0, else: 1), row.id}
end
