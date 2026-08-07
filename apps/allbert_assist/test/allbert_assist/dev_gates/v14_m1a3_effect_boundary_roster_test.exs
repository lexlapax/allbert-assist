defmodule AllbertAssist.DevGates.V14M1A3EffectBoundaryRosterTest do
  use ExUnit.Case, async: true

  @fixture Path.expand("../../fixtures/v1.4/m1a3_effect_boundaries.json", __DIR__)
  @registry_ledger Path.expand("../../fixtures/v1.4/m0_registry_ledger.json", __DIR__)
  @source_roots [
    "apps/allbert_assist/lib",
    "apps/allbert_assist_web/lib",
    "apps/allbert_composition/lib",
    "plugins/*/lib"
  ]
  @required_fields ~w[
    id owner entrypoint source_path phase admission_mode carrier_policy
    missing_or_stale_result compatibility_provenance focused_test
  ]

  @candidate_fields ~w[source_path line boundary disposition roster_id evidence]
  @multi_owner_candidate_fields ~w[source_path line boundary disposition roster_ids evidence]
  @effect_boundaries %{
    "AllbertAssist.Actions.Runner" => MapSet.new([:run]),
    "AllbertAssist.Channels" => MapSet.new([:create_event, :update_event]),
    "AllbertAssist.Channels.Notify" =>
      MapSet.new([
        :accept_consent,
        :deliver,
        :mark_consent_offer_delivered,
        :prepare_consent_offer
      ]),
    "AllbertAssist.Channels.Outbound" => MapSet.new([:edit, :send]),
    "AllbertAssist.Confirmations" =>
      MapSet.new([:annotate_resolution, :create, :expire, :resolve]),
    "AllbertAssist.Jobs.Runner" => MapSet.new([:execute_run, :run_now]),
    "AllbertAssist.Objectives" =>
      MapSet.new([
        :create_event,
        :create_objective,
        :create_step,
        :transition_step,
        :update_objective,
        :update_step
      ]),
    "AllbertAssist.Objectives.Engine.Agent" => MapSet.new([:execute_step, :observe_step]),
    "AllbertAssist.Runtime" => MapSet.new([:acknowledge_deliveries, :submit_user_input]),
    "AllbertAssist.Settings" => MapSet.new([:delete, :put, :write_user_settings]),
    "AllbertAssist.Surface.EventRecorder" =>
      MapSet.new([
        :mark_failed,
        :mark_rejected,
        :mark_result,
        :mark_result_durable,
        :record_inbound
      ]),
    "DynamicSupervisor" => MapSet.new([:start_child]),
    "Req" => MapSet.new([:get, :post, :request]),
    "Supervisor" => MapSet.new([:start_child]),
    "Task.Supervisor" => MapSet.new([:start_child])
  }

  test "the generated roster has one complete, phase-classified row for every boundary" do
    fixture = load_fixture!()
    rows = fixture["rows"]

    assert fixture["schema_version"] == 1
    assert fixture["normalization"] == "v14_m1a3_effect_boundaries_v1"
    assert is_list(rows) and rows != []
    assert Enum.uniq_by(rows, & &1["id"]) == rows

    Enum.each(rows, fn row ->
      assert Map.keys(row) |> Enum.sort() == Enum.sort(@required_fields)
      assert row["phase"] in ["ready", "authorizing"]
      assert row["admission_mode"] in ["ready_carried", "ready_compat_admit", "authorizing_boot"]
      assert File.regular?(project_path(row["source_path"]))

      case row["admission_mode"] do
        "ready_compat_admit" -> assert is_binary(row["compatibility_provenance"])
        _other -> assert is_nil(row["compatibility_provenance"])
      end
    end)
  end

  test "the production callsite discovery classifies every central effect boundary" do
    fixture = load_fixture!()
    rows_by_id = Map.new(fixture["rows"], &{&1["id"], &1})
    classifications = fixture["candidate_classifications"] || []

    assert Enum.uniq_by(classifications, &Map.take(&1, ["source_path", "line", "boundary"])) ==
             classifications,
           "candidate classifications must be unique by source path, line, and boundary"

    Enum.each(classifications, fn classification ->
      assert (Map.keys(classification) |> Enum.sort()) in [
               Enum.sort(@candidate_fields),
               Enum.sort(@multi_owner_candidate_fields)
             ]

      assert is_binary(classification["evidence"]) and classification["evidence"] != ""
      assert is_integer(classification["line"]) and classification["line"] > 0
      assert classification["disposition"] in ["external_e1", "inherited_context", "pure_inert"]

      roster_ids = classification_roster_ids(classification)

      case classification["disposition"] do
        "pure_inert" ->
          assert roster_ids == []
          assert classification["evidence"] =~ "inert" or classification["evidence"] =~ "pure"

        _carried_or_authorizing ->
          assert roster_ids != [] and Enum.uniq(roster_ids) == roster_ids

          rosters =
            Enum.map(roster_ids, fn roster_id ->
              case Map.fetch(rows_by_id, roster_id) do
                {:ok, roster} ->
                  roster

                :error ->
                  flunk(
                    "#{classification["source_path"]}:#{classification["line"]} has no roster classification"
                  )
              end
            end)

          Enum.each(rosters, fn roster ->
            assert is_binary(roster["owner"]) and roster["owner"] != ""
            assert roster["carrier_policy"] =~ ~r/(epoch|E1)/ or roster["phase"] == "authorizing"
            assert roster["missing_or_stale_result"] != ""
            assert roster["focused_test"] != ""
          end)

          if classification["disposition"] == "external_e1" do
            assert roster_ids |> length() == 1
            assert hd(rosters)["source_path"] == classification["source_path"]
          else
            assert classification["evidence"] =~ "Runner" or
                     classification["evidence"] =~ "adapter" or
                     classification["evidence"] =~ "owner"
          end
      end
    end)

    classified = MapSet.new(classifications, &Map.take(&1, ["source_path", "line", "boundary"]))
    discovered = MapSet.new(discovered_effect_calls())

    missing = MapSet.difference(discovered, classified) |> MapSet.to_list() |> Enum.sort()
    stale = MapSet.difference(classified, discovered) |> MapSet.to_list() |> Enum.sort()

    missing_sources = missing |> Enum.map(& &1["source_path"]) |> Enum.uniq() |> Enum.sort()

    assert missing == [],
           "#{MapSet.size(discovered)} discovered effect candidates, #{MapSet.size(classified)} classified; " <>
             "#{length(missing)} unresolved candidates across #{length(missing_sources)} sources (" <>
             "add external E1, inherited-context, or pure/inert classification):\n" <>
             inspect(missing_sources, pretty: true, limit: :infinity) <>
             "\n\n" <>
             inspect(missing, pretty: true, limit: :infinity)

    assert stale == [],
           "stale effect candidate classifications:\n" <>
             inspect(stale, pretty: true, limit: :infinity)
  end

  test "callsite discovery resolves grouped, qualified, and renamed aliases from the production AST" do
    source = """
    alias AllbertAssist.{Actions.Runner, Channels}
    alias AllbertAssist.Settings, as: Config

    def dispatch(context) do
      Runner.run(:sample, %{}, context)
      Channels.create_event(:sample, %{})
      AllbertAssist.Runtime.submit_user_input(:sample, %{}, context)
      Config.put(:sample, %{})
    end
    """

    assert discover_effect_calls_in_source(source)
           |> Enum.map(& &1.boundary)
           |> Enum.sort() == [
             "AllbertAssist.Actions.Runner.run",
             "AllbertAssist.Channels.create_event",
             "AllbertAssist.Runtime.submit_user_input",
             "AllbertAssist.Settings.put"
           ]
  end

  test "callsite discovery treats every M0-registered action module as a direct-run boundary" do
    source = """
    alias AllbertAssist.Actions.Intent.DirectAnswer
    alias AllbertBrowser.Actions.StartSession

    def evaluate(context) do
      DirectAnswer.run(%{text: "probe"}, context)
      StartSession.run(%{}, context)
      AllbertBrowser.Actions.Doctor.run(%{}, context)
    end
    """

    assert discover_effect_calls_in_source(source) |> Enum.map(& &1.boundary) |> Enum.sort() == [
             "AllbertAssist.Actions.Intent.DirectAnswer.run",
             "AllbertBrowser.Actions.Doctor.run",
             "AllbertBrowser.Actions.StartSession.run"
           ]
  end

  test "guard and carrier source inventories remain complete supplements to production callsite discovery" do
    fixture = load_fixture!()

    assert source_paths_matching(~r/\bEffectGuard\b/) == fixture["expected_effect_guard_sources"]

    assert source_paths_matching(~r/\bActivationGuard\./) ==
             fixture["expected_activation_guard_sources"]

    assert source_paths_matching(~r/\ballbert_pack_epoch\b/) == fixture["expected_epoch_sources"]

    row_paths = fixture["rows"] |> Enum.map(& &1["source_path"]) |> MapSet.new()

    classified_paths =
      fixture["candidate_classifications"]
      |> Enum.filter(&(&1["disposition"] != "pure_inert"))
      |> Enum.map(& &1["source_path"])
      |> MapSet.new()

    Enum.each(
      fixture["expected_effect_guard_sources"] ++ fixture["expected_epoch_sources"],
      fn path ->
        assert MapSet.member?(row_paths, path) or MapSet.member?(classified_paths, path),
               "missing roster owner or inherited classification for #{path}"
      end
    )

    Enum.each(
      fixture["expected_activation_guard_sources"],
      fn path -> assert MapSet.member?(row_paths, path), "missing roster row for #{path}" end
    )
  end

  test "the readiness epoch is never smuggled through process-local state" do
    matches =
      @source_roots
      |> Enum.flat_map(fn root ->
        Path.wildcard(Path.join([project_root(), root, "**", "*.ex"]))
      end)
      |> Enum.flat_map(fn path ->
        path
        |> File.stream!()
        |> Stream.with_index(1)
        |> Enum.flat_map(fn {line, line_number} ->
          if line =~ ~r/Process\.(?:get|put|delete).*allbert_pack_epoch/ do
            ["#{Path.relative_to(path, project_root())}:#{line_number}:#{String.trim(line)}"]
          else
            []
          end
        end)
      end)

    assert matches == [],
           "readiness must use an explicit E1 carrier, never process-local state:\n" <>
             Enum.join(matches, "\n")
  end

  test "compatibility admission is restricted to enumerated frozen facades" do
    fixture = load_fixture!()

    compatibility =
      fixture["rows"]
      |> Enum.filter(&(&1["admission_mode"] == "ready_compat_admit"))
      |> Enum.map(& &1["id"])
      |> MapSet.new()

    assert compatibility ==
             MapSet.new([
               "runner-run-3",
               "runner-run-2",
               "runtime-submit-1",
               "cli-run-1",
               "cli-run-attached-1",
               "app-registry-register-2",
               "plugin-registry-register"
             ])
  end

  test "activation is accepted only through the internal carrier at rostered authorizing callsites" do
    fixture = load_fixture!()

    authorizing_rows = Enum.filter(fixture["rows"], &(&1["phase"] == "authorizing"))

    assert authorizing_rows != []

    Enum.each(authorizing_rows, fn row ->
      source = File.read!(project_path(row["source_path"]))

      assert source =~ ":allbert_pack_activation",
             "#{row["id"]} must accept only the internal :allbert_pack_activation carrier"

      assert source =~ "ActivationGuard.validate",
             "#{row["id"]} must validate the authorizing carrier"
    end)

    activation_key_sources = source_paths_matching(~r/\ballbert_pack_activation\b/)
    authorizing_paths = authorizing_rows |> Enum.map(& &1["source_path"]) |> MapSet.new()
    rejection_paths = MapSet.new(fixture["expected_activation_rejection_sources"])

    assert activation_key_sources
           |> Enum.reject(
             &(MapSet.member?(authorizing_paths, &1) or MapSet.member?(rejection_paths, &1))
           ) == [],
           "public/steady-state source accepts the activation carrier"

    Enum.each(fixture["expected_activation_rejection_sources"], fn path ->
      assert File.read!(project_path(path)) =~ "{:error, :product_not_ready}"
    end)
  end

  defp load_fixture! do
    @fixture
    |> File.read!()
    |> Jason.decode!()
  end

  defp classification_roster_ids(%{"roster_id" => ""}), do: []
  defp classification_roster_ids(%{"roster_id" => roster_id}), do: [roster_id]

  defp classification_roster_ids(%{"roster_ids" => roster_ids}) when is_list(roster_ids),
    do: roster_ids

  defp classification_roster_ids(_classification), do: []

  defp effect_boundaries do
    Map.merge(
      @effect_boundaries,
      action_modules_from_frozen_ledger()
      |> Map.new(&{&1, MapSet.new([:run])})
    )
  end

  defp action_modules_from_frozen_ledger do
    ledger = @registry_ledger |> File.read!() |> Jason.decode!()

    ledger["payload"]["actions"]["rows"]
    |> Enum.map(& &1["module"])
    |> Kernel.++(collect_action_modules(ledger))
    |> MapSet.new()
    |> MapSet.to_list()
  end

  defp collect_action_modules(%{} = value) do
    direct =
      case value do
        %{"action_module" => module} when is_binary(module) -> [module]
        _other -> []
      end

    direct ++ Enum.flat_map(Map.values(value), &collect_action_modules/1)
  end

  defp collect_action_modules(values) when is_list(values),
    do: Enum.flat_map(values, &collect_action_modules/1)

  defp collect_action_modules(_value), do: []

  defp source_paths_matching(pattern) do
    @source_roots
    |> Enum.flat_map(fn root ->
      Path.wildcard(Path.join([project_root(), root, "**", "*.ex"]))
    end)
    |> Enum.filter(&(File.read!(&1) =~ pattern))
    |> Enum.map(&Path.relative_to(&1, project_root()))
    |> Enum.sort()
  end

  def discovered_effect_calls do
    @source_roots
    |> Enum.flat_map(fn root ->
      Path.wildcard(Path.join([project_root(), root, "**", "*.ex"]))
    end)
    |> Enum.flat_map(&discover_effect_calls_in_file/1)
    |> Enum.sort()
  end

  defp discover_effect_calls_in_file(path) do
    source = File.read!(path)
    relative_path = Path.relative_to(path, project_root())

    source
    |> discover_effect_calls_in_source()
    |> Enum.map(fn %{line: line, boundary: boundary} ->
      %{
        "source_path" => relative_path,
        "line" => line,
        "boundary" => boundary
      }
    end)
  end

  defp discover_effect_calls_in_source(source) do
    ast = Code.string_to_quoted!(source)
    calls(ast, aliases(ast), effect_boundaries())
  end

  defp calls(ast, aliases, boundaries) do
    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _dot_meta, [module_ast, function]}, call_meta, args} = node, calls
        when is_atom(function) and is_list(args) ->
          case canonical_module(module_ast, aliases, boundaries) do
            module when is_map_key(boundaries, module) ->
              if MapSet.member?(Map.fetch!(boundaries, module), function) do
                # A piped call carries its first argument in the surrounding
                # AST, so the local argument list alone is not the public
                # arity. The file/line pair identifies the callsite exactly.
                boundary = "#{module}.#{function}"
                {node, [%{line: Keyword.fetch!(call_meta, :line), boundary: boundary} | calls]}
              else
                {node, calls}
              end

            _other ->
              {node, calls}
          end

        node, calls ->
          {node, calls}
      end)

    calls
  end

  defp aliases(ast) do
    {_ast, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _meta, arguments} = node, aliases ->
          {node, register_aliases(arguments, aliases)}

        node, aliases ->
          {node, aliases}
      end)

    aliases
  end

  defp register_aliases(arguments, aliases) do
    {targets, options} = Enum.split_while(arguments, &(not is_list(&1)))
    custom_alias = options |> List.flatten() |> Keyword.get(:as) |> alias_name()

    targets
    |> Enum.flat_map(&alias_targets/1)
    |> Enum.reduce(aliases, fn module, aliases ->
      name = custom_alias || module |> String.split(".") |> List.last()
      register_alias(aliases, name, module)
    end)
  end

  defp alias_targets({:__aliases__, _meta, parts}) do
    [Enum.join(parts, ".")]
  end

  defp alias_targets(
         {{:., _dot_meta, [{:__aliases__, _prefix_meta, prefix}, :{}]}, _group_meta, members}
       ) do
    Enum.map(members, fn {:__aliases__, _member_meta, member} ->
      Enum.join(prefix ++ member, ".")
    end)
  end

  defp alias_targets(_other), do: []

  defp alias_name({:__aliases__, _meta, parts}), do: Enum.join(parts, ".")
  defp alias_name(_other), do: nil

  defp register_alias(aliases, name, module) do
    Map.update(aliases, name, module, fn
      ^module -> module
      _other -> :ambiguous
    end)
  end

  defp canonical_module({:__aliases__, _meta, parts}, aliases, boundaries) do
    name = Enum.join(parts, ".")

    cond do
      Map.has_key?(boundaries, name) -> name
      true -> expand_alias(name, aliases)
    end
  end

  defp canonical_module(_other, _aliases, _boundaries), do: nil

  defp expand_alias(name, aliases) do
    name
    |> String.split(".")
    |> Enum.reduce_while([], fn part, resolved ->
      candidate = Enum.join(resolved ++ [part], ".")

      cond do
        Map.get(aliases, candidate) == :ambiguous ->
          {:halt, nil}

        Map.has_key?(aliases, candidate) ->
          {:halt, aliases[candidate] <> suffix(name, candidate)}

        resolved == [] and Map.get(aliases, part) == :ambiguous ->
          {:halt, nil}

        resolved == [] and Map.has_key?(aliases, part) ->
          {:halt, aliases[part] <> suffix(name, part)}

        true ->
          {:cont, resolved ++ [part]}
      end
    end)
    |> case do
      [] -> nil
      nil -> nil
      module -> module
    end
  end

  defp suffix(name, prefix) do
    case String.replace_prefix(name, prefix, "") do
      "" -> ""
      rest -> rest
    end
  end

  defp project_path(path), do: Path.join(project_root(), path)
  defp project_root, do: Path.expand("../../../../..", __DIR__)
end
