defmodule AllbertAssist.DevGates.GateOwners do
  @moduledoc """
  Composes and validates application/Pack-contributed gate-owner manifests.

  This module is generic gate tooling, not an owner registry: owner identities
  and paths originate only in OTP application declarations and Pack callbacks.
  Completeness is checked against a separate filesystem and application census
  so an omitted contributor cannot make its own omission look complete.
  """

  @required_fields [
    :owner_id,
    :application,
    :cwd,
    :production_source_roots,
    :test_roots,
    :test_support_roots,
    :allowed_primary_lanes,
    :aggregate_policy,
    :target_resolver,
    :historical_metrics_aliases
  ]

  @aggregate_policies [:mix_test, :allbert_test_raw]

  alias AllbertAssist.Pack.{Projection, Row, RowSchemas}
  alias AllbertAssist.Pack.RowSchemas.Input

  @spec load!(String.t(), keyword()) :: [map()]
  def load!(repository_root, opts \\ []) when is_binary(repository_root) do
    applications =
      Keyword.get_lazy(opts, :applications, fn -> application_census!(repository_root) end)

    records =
      repository_root
      |> canonical_projection!(Keyword.put(opts, :applications, applications))
      |> Enum.map(& &1.record)

    validate!(records, repository_root, applications)
  end

  @doc "Returns the canonical validated gate-owner carrier rows and their source records."
  @spec canonical_projection!(String.t(), keyword()) :: [map()]
  def canonical_projection!(repository_root, opts \\ []) when is_binary(repository_root) do
    applications =
      Keyword.get_lazy(opts, :applications, fn -> application_census!(repository_root) end)

    contributors =
      Keyword.get_lazy(opts, :contributors, fn ->
        contributor_modules!(applications, repository_root)
      end)

    contributors
    |> Enum.flat_map(fn {application, module, pack_owner_id} ->
      module.test_lanes()
      |> Enum.map(fn raw ->
        record = normalize_record!(raw, application, module)

        %{
          application: application,
          pack_owner_id: pack_owner_id,
          record: record,
          row: canonical_row!(record, pack_owner_id || "application:#{application}")
        }
      end)
    end)
    |> Enum.sort_by(&Atom.to_string(&1.record.owner_id))
  end

  @doc "Returns canonical test-lane Rows contributed by descriptor-bearing Pack applications."
  @spec canonical_pack_rows!(Projection.Closed.t(), keyword()) :: [Row.t()]
  def canonical_pack_rows!(%Projection.Closed{} = closed, opts \\ []) do
    repository_root = Keyword.get(opts, :repository_root, repository_root!())

    repository_root
    |> canonical_projection!(applications: closed.closed_applications)
    |> Enum.reject(&is_nil(&1.pack_owner_id))
    |> Enum.map(& &1.row)
  end

  @doc "Groups canonical Pack-backed gate-owner rows by Pack owner id."
  @spec canonical_pack_rows_by_owner!(Projection.Closed.t(), keyword()) :: %{
          String.t() => [Row.t()]
        }
  def canonical_pack_rows_by_owner!(%Projection.Closed{} = closed, opts \\ []) do
    closed
    |> canonical_pack_rows!(opts)
    |> Enum.group_by(& &1.owner_id)
  end

  @spec validate!([map()], String.t(), [atom()]) :: [map()]
  def validate!(records, repository_root, applications)
      when is_list(records) and is_binary(repository_root) and is_list(applications) do
    issues =
      schema_issues(records) ++
        duplicate_owner_issues(records) ++
        duplicate_claim_issues(records) ++
        path_issues(records, repository_root) ++
        application_issues(records, applications) ++
        independent_production_census_issues(records, repository_root) ++
        independent_test_census_issues(records, repository_root) ++
        independent_support_census_issues(records, repository_root)

    if issues == [] do
      records
    else
      raise ArgumentError,
            "gate-owner manifest validation failed:\n" <>
              Enum.map_join(issues, "\n", &"  - #{&1}")
    end
  end

  @spec application_census!(String.t()) :: [atom()]
  def application_census!(repository_root) do
    applications =
      repository_root
      |> Path.join("apps/*/mix.exs")
      |> Path.wildcard()
      |> Enum.map(fn path ->
        source = File.read!(path)

        case Regex.run(~r/\bapp:\s*:([a-zA-Z0-9_]+)/, source, capture: :all_but_first) do
          [application] -> String.to_atom(application)
          _other -> raise ArgumentError, "cannot census OTP application from #{path}"
        end
      end)
      |> Enum.sort()

    if applications == [], do: raise(ArgumentError, "gate-owner application census is empty")
    applications
  end

  @spec independent_test_files(String.t()) :: [String.t()]
  def independent_test_files(repository_root) do
    ["apps/*/test/**/*_test.exs", "plugins/*/test/**/*_test.exs"]
    |> Enum.flat_map(&Path.wildcard(Path.join(repository_root, &1)))
    |> Enum.map(&Path.relative_to(&1, repository_root))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec independent_support_files(String.t()) :: [String.t()]
  def independent_support_files(repository_root) do
    [
      "apps/*/test/support/**/*",
      "plugins/*/test/support/**/*",
      "apps/*/test/test_helper.exs",
      "plugins/*/test/test_helper.exs"
    ]
    |> Enum.flat_map(&Path.wildcard(Path.join(repository_root, &1)))
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, repository_root))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec independent_production_files(String.t()) :: [String.t()]
  def independent_production_files(repository_root) do
    ["apps/*/lib/**/*", "plugins/*/lib/**/*"]
    |> Enum.flat_map(&Path.wildcard(Path.join(repository_root, &1)))
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, repository_root))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Reads an owner-resolved production/test path or an intentionally fixed
  repository path such as release documentation.

  Source-reading evaluations use this boundary so relocatable application and
  Pack obligations follow their logical `lib/` or `test/` suffix. Other paths
  remain exact and fail when stale.
  """
  @spec read_owned_path!(String.t(), String.t()) :: binary()
  def read_owned_path!(repository_root, relative_path) do
    resolved_path =
      cond do
        relocatable_source_path?(relative_path) ->
          cached_records!(repository_root)
          |> resolve_source_target!(relative_path, repository_root, repository_root)
          |> Map.fetch!(:path)

        relocatable_test_path?(relative_path) ->
          cached_records!(repository_root)
          |> resolve_test_target!(relative_path, repository_root, repository_root)
          |> Map.fetch!(:path)

        true ->
          relative_path
      end

    path = Path.join(repository_root, resolved_path)

    if File.regular?(path),
      do: File.read!(path),
      else: raise(ArgumentError, "stale fixed gate source path #{relative_path}")
  end

  @spec owner_for_test_path!([map()], String.t()) :: map()
  def owner_for_test_path!(records, path) do
    owner_for_path!(records, path, :test_roots, "gate test target")
  end

  @spec owner_for_source_path!([map()], String.t()) :: map()
  def owner_for_source_path!(records, path) do
    owner_for_path!(records, path, :production_source_roots, "gate source target")
  end

  defp owner_for_path!(records, path, field, label) do
    case Enum.filter(records, &under_any_root?(path, Map.fetch!(&1, field))) do
      [owner] -> owner
      [] -> raise ArgumentError, "unowned #{label} #{path}"
      owners -> raise ArgumentError, "duplicate #{label} #{path}: #{owner_ids(owners)}"
    end
  end

  @spec resolve_test_target!([map()], String.t(), String.t(), String.t()) :: map()
  def resolve_test_target!(records, target, from_cwd, repository_root) do
    resolve_target!(records, target, from_cwd, repository_root, :test_roots, "test")
  end

  @spec resolve_source_target!([map()], String.t(), String.t(), String.t()) :: map()
  def resolve_source_target!(records, target, from_cwd, repository_root) do
    resolve_target!(
      records,
      target,
      from_cwd,
      repository_root,
      :production_source_roots,
      "source"
    )
  end

  defp resolve_target!(records, target, from_cwd, repository_root, field, label) do
    repository_path = repository_relative_path!(target, from_cwd, repository_root)

    if File.exists?(Path.join(repository_root, repository_path)) do
      owner = owner_for_path!(records, repository_path, field, "gate #{label} target")
      %{owner_id: owner.owner_id, owner: owner, path: repository_path}
    else
      records
      |> Enum.flat_map(&resolver_matches(&1, target, from_cwd, repository_root))
      |> Enum.uniq_by(&{&1.owner_id, &1.path})
      |> resolve_target_resolution!(target, from_cwd, label)
    end
  end

  defp resolver_matches(owner, target, from_cwd, repository_root) do
    {module, function} = owner.target_resolver

    case apply(module, function, [owner, target, from_cwd, repository_root]) do
      {:ok, resolution} -> [Map.put(resolution, :owner, owner)]
      {:error, _reason} -> []
      other -> raise ArgumentError, "invalid target resolver result: #{inspect(other)}"
    end
  end

  defp resolve_target_resolution!([resolution], _target, _from_cwd, _label), do: resolution

  defp resolve_target_resolution!([], target, from_cwd, label),
    do: raise(ArgumentError, "unresolved gate #{label} target #{target} from #{from_cwd}")

  defp resolve_target_resolution!(many, target, _from_cwd, label),
    do: raise(ArgumentError, "duplicate gate #{label} target #{target}: #{owner_ids(many)}")

  defp repository_relative_path!(target, from_cwd, repository_root) do
    relative = target |> Path.expand(from_cwd) |> Path.relative_to(repository_root)

    if relative == ".." or String.starts_with?(relative, "../") do
      raise ArgumentError, "gate target is outside repository: #{target}"
    end

    relative
  end

  defp contributor_modules!(applications, repository_root) do
    Enum.flat_map(applications, fn application ->
      {app_path, env} = compiled_application_env!(application, repository_root)
      modules = contributor_module_list(env)

      if modules == [] do
        raise ArgumentError, "OTP application #{application} contributes no gate-owner manifest"
      end

      pack_module = Keyword.get(env, :allbert_pack)
      pack_owner_id = pack_owner_id!(pack_module, app_path)

      Enum.map(
        modules,
        &contributor_entry(&1, application, app_path, pack_module, pack_owner_id)
      )
    end)
  end

  defp contributor_module_list(env) do
    [
      Keyword.get(env, :allbert_pack)
      | List.wrap(Keyword.get(env, :allbert_gate_owner_manifests))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp contributor_entry(module, application, app_path, pack_module, pack_owner_id) do
    load_contributor!(module, app_path)
    ensure_test_lanes_exported!(module, application)

    {application, module, if(module == pack_module, do: pack_owner_id, else: nil)}
  end

  defp ensure_test_lanes_exported!(module, application) do
    unless function_exported?(module, :test_lanes, 0) do
      raise ArgumentError,
            "gate-owner contributor #{inspect(module)} for #{application} does not export test_lanes/0"
    end
  end

  defp cached_records!(repository_root) do
    key = {__MODULE__, :records, repository_root}

    case :persistent_term.get(key, :missing) do
      :missing ->
        records = load!(repository_root)
        :persistent_term.put(key, records)
        records

      records ->
        records
    end
  end

  defp compiled_application_env!(application, repository_root) do
    path = application_spec_path!(application, repository_root)

    case :file.consult(String.to_charlist(path)) do
      {:ok, [{:application, ^application, properties}]} ->
        {path, Keyword.get(properties, :env, [])}

      {:error, reason} ->
        raise ArgumentError, "cannot read #{path}: #{inspect(reason)}"

      other ->
        raise ArgumentError, "invalid compiled application spec #{path}: #{inspect(other)}"
    end
  end

  defp application_spec_path!(application, repository_root) do
    filename = ~c"#{application}.app"

    code_path =
      case :code.where_is_file(filename) do
        :non_existing -> nil
        path when is_list(path) -> List.to_string(path)
      end

    build_path =
      Path.join([
        repository_root,
        "_build",
        System.get_env("MIX_ENV") || "dev",
        "lib",
        Atom.to_string(application),
        "ebin",
        Atom.to_string(application) <> ".app"
      ])

    case Enum.find([code_path, build_path], &(is_binary(&1) and File.regular?(&1))) do
      nil ->
        raise ArgumentError,
              "cannot resolve #{application} application spec from code path or #{build_path}"

      path ->
        path
    end
  end

  defp load_contributor!(module, app_path) do
    if Code.ensure_loaded?(module) do
      :ok
    else
      beam = Path.join(Path.dirname(app_path), Atom.to_string(module) <> ".beam")

      with {:ok, bytes} <- File.read(beam),
           {:module, ^module} <-
             :code.load_binary(module, String.to_charlist(beam), bytes) do
        :ok
      else
        reason ->
          raise ArgumentError,
                "cannot load gate-owner contributor #{inspect(module)} from #{beam}: #{inspect(reason)}"
      end
    end
  end

  defp pack_owner_id!(nil, _app_path), do: nil

  defp pack_owner_id!(module, app_path) do
    load_contributor!(module, app_path)

    case module.descriptor() do
      %{id: id} when is_binary(id) and id != "" ->
        id

      descriptor ->
        raise ArgumentError, "invalid Pack descriptor for gate owner: #{inspect(descriptor)}"
    end
  end

  defp repository_root! do
    case System.get_env("ALLBERT_REPOSITORY_ROOT") do
      root when is_binary(root) and root != "" -> Path.expand(root)
      _ -> Path.expand("../../../../..", __DIR__)
    end
  end

  defp canonical_row!(record, pack_owner_id) do
    {resolver_module, resolver_function} = record.target_resolver

    payload = %{
      "owner_id" => Atom.to_string(record.owner_id),
      "application" => Atom.to_string(record.application),
      "cwd" => record.cwd,
      "production_roots" => record.production_source_roots,
      "test_roots" => record.test_roots,
      "support_roots" => record.test_support_roots,
      "allowed_primary_lanes" => Enum.map(record.allowed_primary_lanes, &Atom.to_string/1),
      "aggregate_policy" => Atom.to_string(record.aggregate_policy),
      "target_resolver_module" => module_name(resolver_module),
      "target_resolver_function" => Atom.to_string(resolver_function),
      "historical_metrics_aliases" => record.historical_metrics_aliases
    }

    placeholder = Map.put(payload, "projection_sha256", String.duplicate("0", 64))

    digest =
      RowSchemas.reference_digest_for!(:test_lane_v1, %Input{
        payload: placeholder,
        source_authority: %{}
      })

    normalized =
      RowSchemas.normalize!(:test_lane_v1, %Input{
        payload: Map.put(payload, "projection_sha256", digest),
        source_authority: %{}
      })

    %Row{
      schema_version: 1,
      kind: :test_lanes,
      owner_id: pack_owner_id,
      identity: %{namespace: :owner_id, value: Atom.to_string(record.owner_id)},
      order: %{namespace: :lexical, value: Atom.to_string(record.owner_id)},
      payload_schema: :test_lane_v1,
      payload: RowSchemas.canonical_projection(normalized),
      source_authority: RowSchemas.source_authority_projection(normalized),
      m0_payload_sha256: nil
    }
  end

  defp module_name(module),
    do: module |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

  defp normalize_record!(record, application, contributor) when is_map(record) do
    record = Map.new(record, fn {key, value} -> {normalize_key(key), value} end)
    missing = @required_fields -- Map.keys(record)

    if missing != [] do
      raise ArgumentError,
            "gate-owner contributor #{inspect(contributor)} record is missing #{inspect(missing)}"
    end

    declared_application = normalize_application(record.application)

    if declared_application != application do
      raise ArgumentError,
            "gate owner #{inspect(record.owner_id)} declares #{declared_application}, expected contributor application #{application}"
    end

    %{
      owner_id: normalize_owner_id(record.owner_id),
      application: declared_application,
      cwd: record.cwd,
      production_source_roots: List.wrap(record.production_source_roots),
      test_roots: List.wrap(record.test_roots),
      test_support_roots: List.wrap(record.test_support_roots),
      allowed_primary_lanes: Enum.map(List.wrap(record.allowed_primary_lanes), &normalize_lane/1),
      aggregate_policy: normalize_policy(record.aggregate_policy),
      target_resolver: normalize_resolver(record.target_resolver),
      historical_metrics_aliases: List.wrap(record.historical_metrics_aliases)
    }
  end

  defp normalize_record!(record, _application, contributor) do
    raise ArgumentError,
          "gate-owner contributor #{inspect(contributor)} returned non-map #{inspect(record)}"
  end

  defp schema_issues(records) do
    Enum.flat_map(records, fn owner ->
      scalar_paths = [owner.cwd]
      roots = owner.production_source_roots ++ owner.test_roots ++ owner.test_support_roots
      aliases = owner.historical_metrics_aliases
      {module, function} = owner.target_resolver

      []
      |> add_issue(owner.test_roots == [], "owner #{owner.owner_id} declares no test roots")
      |> add_issue(owner.allowed_primary_lanes == [], "owner #{owner.owner_id} declares no lanes")
      |> add_issue(
        owner.aggregate_policy not in @aggregate_policies,
        "owner #{owner.owner_id} has invalid aggregate policy"
      )
      |> add_issue(
        Enum.any?(scalar_paths ++ roots, &(not confined_relative_path?(&1))),
        "owner #{owner.owner_id} has an invalid repository path"
      )
      |> add_issue(
        Enum.any?(aliases, &(not is_binary(&1) or String.trim(&1) == "")),
        "owner #{owner.owner_id} has an invalid metrics alias"
      )
      |> add_issue(
        not (is_atom(module) and is_atom(function) and Code.ensure_loaded?(module) and
               function_exported?(module, function, 4)),
        "owner #{owner.owner_id} target resolver is unavailable"
      )
    end)
  end

  defp duplicate_owner_issues(records) do
    records
    |> Enum.group_by(& &1.owner_id)
    |> Enum.flat_map(fn
      {_owner, [_single]} -> []
      {owner, duplicates} -> ["owner id #{owner} is contributed #{length(duplicates)} times"]
    end)
  end

  defp duplicate_claim_issues(records) do
    exact_issues =
      [
        {:production_source_roots, "production source root"},
        {:test_roots, "test root"},
        {:test_support_roots, "test support root"},
        {:historical_metrics_aliases, "historical metrics alias"}
      ]
      |> Enum.flat_map(fn {field, label} ->
        records
        |> Enum.flat_map(fn owner ->
          Enum.map(Map.fetch!(owner, field), &{&1, owner.owner_id})
        end)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Enum.flat_map(fn
          {_claim, [_owner]} ->
            []

          {claim, owners} ->
            ["#{label} #{claim} is claimed by #{Enum.map_join(owners, ", ", &to_string/1)}"]
        end)
      end)

    exact_issues ++ overlapping_root_issues(records)
  end

  defp overlapping_root_issues(records) do
    roots =
      for owner <- records,
          field <- [:production_source_roots, :test_roots, :test_support_roots],
          root <- Map.fetch!(owner, field),
          do: %{owner: owner.owner_id, field: field, root: root}

    roots
    |> Enum.with_index()
    |> Enum.flat_map(fn {left, index} ->
      roots
      |> Enum.drop(index + 1)
      |> Enum.flat_map(&overlap_issue(left, &1))
    end)
  end

  defp overlap_issue(left, right) do
    if left.owner != right.owner and roots_overlap?(left.root, right.root) do
      [
        "overlapping #{root_label(left.field)} roots #{left.root} (#{left.owner}) and " <>
          "#{right.root} (#{right.owner})"
      ]
    else
      []
    end
  end

  defp roots_overlap?(left, right), do: within?(left, right) or within?(right, left)
  defp root_label(:production_source_roots), do: "production source"
  defp root_label(:test_roots), do: "test"
  defp root_label(:test_support_roots), do: "test support"

  defp path_issues(records, repository_root) do
    Enum.flat_map(records, fn owner ->
      owner
      |> owner_paths()
      |> Enum.flat_map(fn {kind, path} -> path_issue(owner, kind, path, repository_root) end)
    end)
  end

  defp owner_paths(owner) do
    [cwd: owner.cwd] ++
      Enum.map(owner.production_source_roots, &{:production_source_root, &1}) ++
      Enum.map(owner.test_roots, &{:test_root, &1}) ++
      Enum.map(owner.test_support_roots, &{:test_support_root, &1})
  end

  defp path_issue(owner, kind, path, repository_root) do
    if File.dir?(Path.join(repository_root, path)),
      do: [],
      else: ["owner #{owner.owner_id} #{kind} is missing: #{path}"]
  end

  defp application_issues(records, applications) do
    represented = records |> Enum.map(& &1.application) |> MapSet.new()

    applications
    |> Enum.reject(&MapSet.member?(represented, &1))
    |> Enum.map(&"OTP application #{&1} has no gate owner")
  end

  defp independent_test_census_issues(records, repository_root) do
    repository_root
    |> independent_test_files()
    |> Enum.flat_map(&ownership_issues(records, &1, :test_roots, "test file"))
  end

  defp independent_production_census_issues(records, repository_root) do
    repository_root
    |> independent_production_files()
    |> Enum.flat_map(&ownership_issues(records, &1, :production_source_roots, "production file"))
  end

  defp independent_support_census_issues(records, repository_root) do
    repository_root
    |> independent_support_files()
    |> Enum.flat_map(fn path ->
      if Path.basename(path) == "test_helper.exs" do
        ownership_issues(records, path, :test_roots, "test helper")
      else
        ownership_issues(records, path, :test_support_roots, "support file")
      end
    end)
  end

  defp ownership_issues(records, path, field, label) do
    owners = Enum.filter(records, &under_any_root?(path, Map.fetch!(&1, field)))

    case owners do
      [_owner] -> []
      [] -> ["independent census found unowned #{label}: #{path}"]
      many -> ["independent census found duplicate #{label} #{path}: #{owner_ids(many)}"]
    end
  end

  defp under_any_root?(path, roots), do: Enum.any?(roots, &within?(path, &1))
  defp within?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp owner_ids(owners) do
    owners
    |> Enum.map(fn owner -> Map.get(owner, :owner_id) || get_in(owner, [:owner, :owner_id]) end)
    |> Enum.map_join(", ", &to_string/1)
  end

  defp add_issue(issues, true, issue), do: [issue | issues]
  defp add_issue(issues, false, _issue), do: issues

  defp confined_relative_path?(path) when is_binary(path) do
    path != "" and path != "." and Path.type(path) == :relative and
      not Enum.any?(Path.split(path), &(&1 in ["", ".", ".."]))
  end

  defp confined_relative_path?(_path), do: false

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: String.to_existing_atom(key)
  defp normalize_owner_id(value) when is_atom(value), do: value
  defp normalize_owner_id(value) when is_binary(value), do: String.to_atom(value)
  defp normalize_application(value) when is_atom(value), do: value
  defp normalize_application(value) when is_binary(value), do: String.to_atom(value)
  defp normalize_lane(value) when is_atom(value), do: value
  defp normalize_lane(value) when is_binary(value), do: String.to_atom(value)
  defp normalize_policy(value) when is_atom(value), do: value
  defp normalize_policy(value) when is_binary(value), do: String.to_atom(value)

  defp normalize_resolver({module, function}) when is_atom(module) and is_atom(function),
    do: {module, function}

  defp relocatable_source_path?(path),
    do:
      (String.starts_with?(path, "apps/") or String.starts_with?(path, "plugins/")) and
        String.contains?(path, "/lib/")

  defp relocatable_test_path?(path),
    do:
      (String.starts_with?(path, "apps/") or String.starts_with?(path, "plugins/")) and
        String.contains?(path, "/test/")
end
