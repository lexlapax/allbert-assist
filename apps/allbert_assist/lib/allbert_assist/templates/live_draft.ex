defmodule AllbertAssist.Templates.LiveDraft do
  @moduledoc """
  Converts the reviewed v0.38 LLM-tool template into a v0.37 dynamic draft.

  This module is plain deterministic file IO. It writes source evidence under
  Allbert Home only; sandbox evidence, trusted validation, and live authority
  remain owned by the v0.36/v0.37 draft lifecycle.
  """

  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.DynamicPlugins.Audit
  alias AllbertAssist.DynamicPlugins.Draft
  alias AllbertAssist.DynamicPlugins.MetadataStore
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Templates
  alias AllbertAssist.Templates.Renderer

  @live_pattern_id "llm_tool"
  @producer "template_pattern"

  @doc "Render one reviewed LLM-tool pattern into the shared dynamic draft store."
  @spec create(String.t() | atom(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(pattern_id, params, opts \\ [])

  def create(pattern_id, params, opts) when is_map(params) do
    with {:ok, rendered} <- Templates.render(pattern_id, params),
         :ok <- ensure_supported_live_pattern(rendered),
         {:ok, manifest} <- manifest(rendered),
         :ok <- validate_manifest(rendered, manifest),
         slug <- rendered.params["slug"],
         root <- MetadataStore.draft_root(slug),
         :ok <- ensure_new_draft_root(slug, root),
         {:ok, source_files} <- source_files(rendered, manifest),
         :ok <- write_source_files(root, source_files),
         {:ok, source_hashes} <- source_hashes(root, source_files),
         compiled_paths <- compiled_paths(source_files),
         scan_paths <- source_paths(source_files),
         {:ok, draft} <-
           DynamicPlugins.put_draft(%{
             slug: slug,
             producer: @producer,
             template_pattern_id: rendered.pattern_id,
             target_shapes: rendered.target_shapes,
             source_hashes: source_hashes,
             compiled_paths: compiled_paths,
             scan_paths: scan_paths,
             budget: %{
               "provider_calls_used" => 0,
               "provider_usage_units_used" => 0
             },
             diagnostics: diagnostics(rendered, opts),
             static_validation: %{"status" => "not_run"},
             gate: %{"status" => "not_run", "sandbox_report_id" => nil}
           }),
         :ok <- MetadataStore.put_manifest(slug, manifest),
         :ok <- audit_created(draft, rendered, manifest, opts) do
      {:ok,
       %{
         draft: Draft.summary(draft),
         manifest: manifest_summary(manifest),
         files: Enum.map(source_files, &Map.take(&1, [:source_path, :compiled_path, :bytes])),
         next_actions: next_actions(draft.slug),
         diagnostics: draft.diagnostics
       }}
    end
  end

  def create(_pattern_id, _params, _opts), do: {:error, :invalid_template_live_draft_input}

  defp ensure_supported_live_pattern(%{
         pattern_id: @live_pattern_id,
         live_integration?: true,
         target_shapes: ["action"]
       }),
       do: :ok

  defp ensure_supported_live_pattern(%{pattern_id: pattern_id}) do
    {:error, {:unsupported_live_integration_pattern, pattern_id}}
  end

  defp manifest(rendered) do
    rendered.files
    |> Enum.find(&(&1.path == "dynamic_manifest.json"))
    |> case do
      %{content: content} -> Jason.decode(content)
      _other -> {:error, :missing_dynamic_manifest}
    end
  end

  defp validate_manifest(rendered, manifest) when is_map(manifest) do
    with :ok <- require_string_list(manifest, "target_shapes", ["action"]),
         :ok <- require_string_list(manifest, "modules", [rendered.params["action_module"]]),
         :ok <- require_action(rendered, manifest),
         {:ok, entries} <- manifest_entries(manifest),
         :ok <- validate_entries(rendered, entries) do
      :ok
    end
  end

  defp validate_manifest(_rendered, _manifest), do: {:error, :invalid_dynamic_manifest}

  defp require_string_list(manifest, key, expected) do
    case Map.get(manifest, key) do
      ^expected -> :ok
      value -> {:error, {:invalid_dynamic_manifest_field, key, value}}
    end
  end

  defp require_action(rendered, manifest) do
    expected = %{
      "name" => rendered.params["action_name"],
      "module" => rendered.params["action_module"],
      "permission" => rendered.params["permission"],
      "exposure" => "internal"
    }

    case Map.get(manifest, "actions") do
      [^expected] -> :ok
      actions -> {:error, {:invalid_dynamic_manifest_field, "actions", actions}}
    end
  end

  defp manifest_entries(manifest) do
    files = entries(manifest, "files", :source)
    tests = entries(manifest, "tests", :test)

    case files ++ tests do
      [] -> {:error, :dynamic_manifest_empty}
      entries -> {:ok, entries}
    end
  end

  defp entries(manifest, key, kind) do
    manifest
    |> Map.get(key, [])
    |> Enum.map(fn entry ->
      %{
        kind: kind,
        source_path: Map.get(entry, "source_path"),
        compiled_path: Map.get(entry, "compiled_path")
      }
    end)
  end

  defp validate_entries(rendered, entries) do
    rendered_paths = rendered.files |> Enum.map(& &1.path) |> MapSet.new()
    slug = rendered.params["slug"]

    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case validate_entry(entry, rendered_paths, slug) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_entry(
         %{source_path: source_path, compiled_path: compiled_path} = entry,
         paths,
         slug
       ) do
    cond do
      not is_binary(source_path) or not MapSet.member?(paths, source_path) ->
        {:error, {:manifest_source_not_rendered, source_path}}

      not Renderer.safe_relative_path?(source_path) ->
        {:error, {:unsafe_manifest_source_path, source_path}}

      not valid_compiled_path?(entry.kind, slug, compiled_path) ->
        {:error, {:unsafe_manifest_compiled_path, compiled_path}}

      true ->
        :ok
    end
  end

  defp valid_compiled_path?(:source, slug, path) do
    valid_compiled_path?(
      path,
      ["apps", "allbert_assist", "lib", "allbert_assist", "dynamic_plugins", "generated", slug],
      ".ex"
    )
  end

  defp valid_compiled_path?(:test, slug, path) do
    valid_compiled_path?(
      path,
      ["apps", "allbert_assist", "test", "allbert_assist", "dynamic_plugins", "generated", slug],
      ".exs"
    )
  end

  defp valid_compiled_path?(path, prefix, extension) when is_binary(path) do
    segments = Path.split(path)
    Enum.take(segments, length(prefix)) == prefix and Path.extname(path) == extension
  end

  defp valid_compiled_path?(_path, _prefix, _extension), do: false

  defp ensure_new_draft_root(slug, root) do
    if File.exists?(root), do: {:error, {:template_draft_exists, slug}}, else: :ok
  end

  defp source_files(rendered, manifest) do
    rendered_by_path = Map.new(rendered.files, &{&1.path, &1})

    with {:ok, entries} <- manifest_entries(manifest) do
      {:ok,
       Enum.map(entries, fn entry ->
         rendered_file = Map.fetch!(rendered_by_path, entry.source_path)

         entry
         |> Map.put(:content, rendered_file.content)
         |> Map.put(:bytes, rendered_file.bytes)
       end)}
    end
  end

  defp write_source_files(root, files) do
    Enum.reduce_while(files, :ok, fn file, :ok ->
      destination = Path.join(root, file.source_path)

      with :ok <- File.mkdir_p(Path.dirname(destination)),
           :ok <- File.write(destination, file.content) do
        {:cont, :ok}
      else
        {:error, reason} ->
          {:halt, {:error, {:template_draft_write_failed, file.source_path, reason}}}
      end
    end)
  end

  defp source_hashes(root, files) do
    Enum.reduce_while(files, {:ok, %{}}, fn file, {:ok, acc} ->
      path = Path.join(root, file.source_path)

      case MetadataStore.hash_file(path) do
        {:ok, hash} -> {:cont, {:ok, Map.put(acc, file.source_path, hash)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp source_paths(files), do: Enum.map(files, & &1.source_path)
  defp compiled_paths(files), do: Enum.map(files, & &1.compiled_path)

  defp diagnostics(rendered, opts) do
    [
      %{
        "source" => @producer,
        "status" => "draft_created",
        "message" =>
          "Reviewed template draft created; live authority remains unavailable until sandbox gate and explicit integration.",
        "template_pattern_id" => rendered.pattern_id,
        "authority" => "none",
        "operator_id" => Keyword.get(opts, :operator_id),
        "channel" => Keyword.get(opts, :channel),
        "surface" => Keyword.get(opts, :surface)
      }
    ]
    |> Redactor.redact()
  end

  defp audit_created(%Draft{} = draft, rendered, manifest, opts) do
    with {:ok, _path} <-
           Audit.append(:template_draft_created, %{
             slug: draft.slug,
             revision: draft.revision,
             producer: draft.producer,
             template_pattern_id: rendered.pattern_id,
             target_shapes: draft.target_shapes,
             action_name: rendered.params["action_name"],
             permission: rendered.params["permission"],
             focused_test_paths: Map.get(manifest, "focused_test_paths", []),
             operator_id: Keyword.get(opts, :operator_id),
             channel: Keyword.get(opts, :channel),
             surface: Keyword.get(opts, :surface)
           }) do
      :ok
    end
  end

  defp manifest_summary(manifest) do
    %{
      "target_shapes" => Map.get(manifest, "target_shapes", []),
      "modules" => Map.get(manifest, "modules", []),
      "actions" =>
        manifest
        |> Map.get("actions", [])
        |> Enum.map(&Map.take(&1, ["name", "module", "permission", "exposure"])),
      "focused_test_paths" => Map.get(manifest, "focused_test_paths", [])
    }
  end

  defp next_actions(slug) do
    [
      %{name: "run_dynamic_draft_trial", params: %{slug: slug}},
      %{name: "run_dynamic_draft_gate", params: %{slug: slug}},
      %{name: "integrate_dynamic_draft", params: %{slug: slug}}
    ]
  end
end
