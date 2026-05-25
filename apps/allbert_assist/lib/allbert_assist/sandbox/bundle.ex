defmodule AllbertAssist.Sandbox.Bundle do
  @moduledoc """
  Copy-in/copy-out bundle builder for v0.36 Elixir/OTP sandbox trials.

  The bundle receives a disposable project snapshot, draft inputs, focused test
  inputs, report directory, and sandbox-local Allbert Home. It never includes
  the operator's real Allbert Home.
  """

  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime.Redactor

  @allowed_extensions ~w[.app .config .ex .exs .eex .heex .erl .hrl .json .lock .md .yml .yaml]
  @blocked_segments ~w[.git _build deps node_modules priv/static assets vendor .elixir_ls]
  @max_file_bytes 512 * 1024
  @max_total_bytes 64 * 1024 * 1024
  @id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,119}\z/

  @enforce_keys [
    :id,
    :root,
    :project_root,
    :project_path,
    :drafts_path,
    :tests_path,
    :sandbox_home,
    :reports_path,
    :metadata_path
  ]
  defstruct @enforce_keys ++
              [
                project_files: [],
                draft_files: [],
                test_files: [],
                diagnostics: [],
                metadata: %{}
              ]

  @type t :: %__MODULE__{
          id: String.t(),
          root: String.t(),
          project_root: String.t(),
          project_path: String.t(),
          drafts_path: String.t(),
          tests_path: String.t(),
          sandbox_home: String.t(),
          reports_path: String.t(),
          metadata_path: String.t(),
          project_files: [map()],
          draft_files: [map()],
          test_files: [map()],
          diagnostics: [map()],
          metadata: map()
        }

  @spec build(map(), keyword()) :: {:ok, t()} | {:error, map()}
  def build(params, opts \\ []) when is_map(params) do
    with {:ok, project_root} <- require_project_root(params),
         :ok <- reject_real_home(project_root),
         {:ok, manifest} <- input_manifest(params, project_root),
         {:ok, root} <- allocate_root(params, opts),
         {:ok, bundle} <- copy_bundle(root, project_root, manifest, params) do
      {:ok, bundle}
    else
      {:error, reason} -> {:error, error(reason)}
    end
  end

  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = bundle) do
    %{
      id: bundle.id,
      root: bundle.root,
      project_root: redact_path(bundle.project_root),
      project_path: bundle.project_path,
      drafts_path: bundle.drafts_path,
      tests_path: bundle.tests_path,
      sandbox_home: bundle.sandbox_home,
      reports_path: bundle.reports_path,
      metadata_path: bundle.metadata_path,
      project_file_count: length(bundle.project_files),
      draft_file_count: length(bundle.draft_files),
      test_file_count: length(bundle.test_files),
      diagnostics: bundle.diagnostics
    }
  end

  defp require_project_root(params) do
    case value(params, :project_root) do
      root when is_binary(root) ->
        expanded = Path.expand(root)

        if File.dir?(expanded) do
          {:ok, expanded}
        else
          {:error, {:project_root_missing, redact_path(expanded)}}
        end

      other ->
        {:error, {:invalid_project_root, other}}
    end
  end

  defp reject_real_home(path) do
    home = Paths.home()

    if same_or_inside?(path, home) do
      {:error, :real_home_not_allowed}
    else
      :ok
    end
  end

  defp input_manifest(params, project_root) do
    with {:ok, project_files} <- project_files(params, project_root),
         {:ok, draft_files} <- classified_files(value(params, :draft_paths) || [], project_root),
         {:ok, test_files} <- classified_files(value(params, :test_paths) || [], project_root),
         :ok <- enforce_total_size(project_files ++ draft_files ++ test_files) do
      {:ok, %{project: project_files, drafts: draft_files, tests: test_files}}
    end
  end

  defp project_files(params, project_root) do
    case value(params, :project_paths) do
      nil -> default_project_files(project_root)
      paths when is_list(paths) -> classified_files(paths, project_root)
      other -> {:error, {:invalid_project_paths, other}}
    end
  end

  defp default_project_files(project_root) do
    [
      "mix.exs",
      "mix.lock",
      ".formatter.exs",
      ".credo.exs",
      ".dialyzer_ignore.exs",
      "config",
      "apps",
      "plugins"
    ]
    |> Enum.map(&Path.join(project_root, &1))
    |> Enum.filter(&File.exists?/1)
    |> classified_files(project_root)
  end

  defp classified_files(paths, project_root) when is_list(paths) do
    paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case expand_input(path, project_root) do
        {:ok, files} -> {:cont, {:ok, acc ++ files}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.uniq_by(files, & &1.source)}
      error -> error
    end
  end

  defp expand_input(path, project_root) when is_binary(path) do
    expanded = Path.expand(path, project_root)

    with :ok <- validate_input_scope(expanded, project_root),
         :ok <- validate_not_symlink(expanded) do
      expand_scoped_input(expanded, project_root)
    end
  end

  defp expand_input(path, _project_root), do: {:error, {:invalid_input_path, path}}

  defp validate_input_scope(path, project_root) do
    cond do
      not same_or_inside?(path, project_root) ->
        {:error, {:path_outside_project, redact_path(path)}}

      same_or_inside?(path, Paths.home()) ->
        {:error, :real_home_not_allowed}

      true ->
        :ok
    end
  end

  defp validate_not_symlink(path) do
    if symlink?(path), do: {:error, {:symlink_not_allowed, redact_path(path)}}, else: :ok
  end

  defp expand_scoped_input(path, project_root) do
    cond do
      File.regular?(path) -> file_entry(path, project_root)
      File.dir?(path) -> directory_entries(path, project_root)
      true -> {:error, {:input_missing, redact_path(path)}}
    end
  end

  defp directory_entries(path, project_root) do
    path
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&File.dir?/1)
    |> Enum.reduce_while({:ok, []}, &collect_directory_entry(&1, &2, project_root))
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp collect_directory_entry(file, {:ok, acc}, project_root) do
    case file_entry(file, project_root) do
      {:ok, []} -> {:cont, {:ok, acc}}
      {:ok, [entry]} -> {:cont, {:ok, [entry | acc]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp file_entry(path, project_root) do
    relative = Path.relative_to(path, project_root)

    cond do
      blocked_path?(relative) ->
        {:ok, []}

      Path.extname(path) not in @allowed_extensions ->
        {:ok, []}

      symlink?(path) ->
        {:error, {:symlink_not_allowed, redact_path(path)}}

      File.stat!(path).size > @max_file_bytes ->
        {:error, {:file_too_large, redact_path(path)}}

      true ->
        {:ok, [%{source: path, relative: relative, bytes: File.stat!(path).size}]}
    end
  end

  defp enforce_total_size(files) do
    total = files |> Enum.map(& &1.bytes) |> Enum.sum()

    if total <= @max_total_bytes, do: :ok, else: {:error, {:bundle_too_large, total}}
  end

  defp allocate_root(params, opts) do
    id = value(params, :id) || "bundle-#{System.unique_integer([:positive])}"
    bundles_root = Path.expand(Paths.sandbox_bundles_root())

    with :ok <- validate_id(id),
         {:ok, root} <- requested_root(Keyword.get(opts, :root), bundles_root, id) do
      if File.exists?(root) do
        {:error, {:bundle_root_exists, root}}
      else
        {:ok, root}
      end
    end
  end

  defp validate_id(id) when is_binary(id) do
    if Regex.match?(@id_pattern, id) and id not in [".", ".."] do
      :ok
    else
      {:error, {:invalid_bundle_id, id}}
    end
  end

  defp validate_id(id), do: {:error, {:invalid_bundle_id, id}}

  defp requested_root(nil, bundles_root, id), do: {:ok, Path.join(bundles_root, id)}

  defp requested_root(root, bundles_root, _id) when is_binary(root) do
    expanded = Path.expand(root)

    cond do
      expanded == bundles_root ->
        {:error, :sandbox_bundle_root_required}

      same_or_inside?(expanded, bundles_root) ->
        {:ok, expanded}

      true ->
        {:error, {:bundle_root_outside_sandbox, redact_path(expanded)}}
    end
  end

  defp requested_root(root, _bundles_root, _id), do: {:error, {:invalid_bundle_root, root}}

  defp copy_bundle(root, project_root, manifest, params) do
    id = value(params, :id) || Path.basename(root)
    project_path = Path.join(root, "project")
    drafts_path = Path.join(root, "drafts")
    tests_path = Path.join(root, "tests")
    sandbox_home = Path.join(root, "sandbox_home")
    reports_path = Path.join(root, "reports")
    metadata_path = Path.join(root, "metadata.json")

    File.mkdir_p!(project_path)
    File.mkdir_p!(drafts_path)
    File.mkdir_p!(tests_path)
    File.mkdir_p!(sandbox_home)
    File.mkdir_p!(reports_path)
    File.chmod!(sandbox_home, 0o777)
    File.chmod!(reports_path, 0o777)

    project_copies = copy_files!(manifest.project, project_path)
    draft_copies = copy_files!(manifest.drafts, drafts_path)
    test_copies = copy_files!(manifest.tests, tests_path)

    metadata =
      %{
        id: id,
        project_root: redact_path(project_root),
        project_files: redacted_entries(project_copies),
        draft_files: redacted_entries(draft_copies),
        test_files: redacted_entries(test_copies),
        sandbox_home: sandbox_home,
        reports_path: reports_path,
        created_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }
      |> Redactor.redact(:sandbox_trial)

    File.write!(metadata_path, Jason.encode!(metadata, pretty: true))

    {:ok,
     %__MODULE__{
       id: id,
       root: root,
       project_root: project_root,
       project_path: project_path,
       drafts_path: drafts_path,
       tests_path: tests_path,
       sandbox_home: sandbox_home,
       reports_path: reports_path,
       metadata_path: metadata_path,
       project_files: project_copies,
       draft_files: draft_copies,
       test_files: test_copies,
       metadata: metadata
     }}
  rescue
    exception ->
      File.rm_rf(root)
      {:error, {:bundle_build_failed, exception.__struct__, Exception.message(exception)}}
  end

  defp copy_files!(files, target_root) do
    Enum.map(files, fn entry ->
      target = Path.join(target_root, entry.relative)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(entry.source, target)
      Map.put(entry, :target, target)
    end)
  end

  defp redacted_entries(entries) do
    Enum.map(entries, fn entry ->
      %{
        source: redact_path(entry.source),
        target: entry.target,
        relative: entry.relative,
        bytes: entry.bytes
      }
    end)
  end

  defp blocked_path?(relative) do
    relative
    |> Path.split()
    |> Enum.any?(&(&1 in @blocked_segments))
  end

  defp symlink?(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> true
      _other -> false
    end
  end

  defp same_or_inside?(path, root) do
    path = Path.expand(path)
    root = Path.expand(root)
    path == root or String.starts_with?(path, root <> "/")
  end

  defp redact_path(path) when is_binary(path) do
    home = Paths.home()

    path
    |> Path.expand()
    |> String.replace(home, "<ALLBERT_HOME>")
  end

  defp value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp error(reason), do: %{status: :denied, reason: reason, diagnostics: [%{reason: reason}]}
end
