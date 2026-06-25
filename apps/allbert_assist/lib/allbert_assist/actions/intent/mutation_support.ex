defmodule AllbertAssist.Actions.Intent.MutationSupport do
  @moduledoc false

  alias AllbertAssist.Actions.Intent.OperatorSupport
  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.Intent.Eval.{Corpus, Gate, Runner, Scorer}
  alias AllbertAssist.Intent.Router.{DescriptorResolver, DescriptorStore, Index, Optimizer}
  alias AllbertAssist.Maps
  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings.YamlCodec

  @safe_component ~r/^[a-z0-9][a-z0-9_-]*$/
  @fixture_candidates [
    "apps/allbert_assist/test/fixtures/intent/eval",
    "test/fixtures/intent/eval"
  ]

  @spec write_action(String.t(), map(), (PermissionGate.decision() -> {:ok, map()})) ::
          {:ok, map()}
  def write_action(action_name, context, on_allowed) when is_function(on_allowed, 1) do
    permission_decision = PermissionGate.authorize(:settings_write, context)

    if PermissionGate.allowed?(permission_decision) do
      on_allowed.(permission_decision)
    else
      {:ok,
       %{
         message: "Intent descriptor mutation denied by Security Central.",
         status: :denied,
         permission_decision: permission_decision,
         actions: [action(action_name, :denied, permission_decision)]
       }}
    end
  end

  @spec action(String.t(), atom(), PermissionGate.decision(), map()) :: map()
  def action(action_name, status, permission_decision, metadata \\ %{}) do
    Map.merge(
      %{
        name: action_name,
        status: status,
        permission: :settings_write,
        permission_decision: permission_decision
      },
      metadata
    )
  end

  def finish(action_name, result, permission_decision, metadata \\ %{}) do
    status = Map.get(result, :status, :completed)

    {:ok,
     result
     |> Map.put(:permission_decision, permission_decision)
     |> Map.put(:actions, [action(action_name, status, permission_decision, metadata)])}
  end

  @spec optimize(map()) :: {:ok, map()}
  def optimize(params) do
    result = Optimizer.optimize(strategy: strategy(params))
    rejected_count = length(Map.get(result, :rejected, []))

    message =
      [
        "generated=#{length(result.generated)} review_pending=#{length(result.reviewed)} rejected=#{rejected_count}",
        OperatorSupport.render_coverage(result.coverage)
      ]
      |> Enum.join("\n")

    {:ok,
     %{
       message: message,
       status: :completed,
       result: result,
       mutation_metadata: %{
         generated: result.generated,
         reviewed: result.reviewed,
         rejected: Map.get(result, :rejected, [])
       }
     }}
  end

  def reindex do
    state = Index.rebuild()
    message = "index status=#{state.status} size=#{length(state.entries)}"

    {:ok,
     %{
       message: message,
       status: :completed,
       index: %{status: state.status, size: length(state.entries)}
     }}
  end

  @spec edit(String.t()) :: {:ok, map()}
  def edit(action_name) do
    case descriptor_for_action(action_name) do
      nil ->
        {:ok, rejected("no resolved descriptor for #{action_name}", :not_found)}

      descriptor ->
        attrs = override_attrs(descriptor)

        with :ok <- Gate.check_promotion(attrs),
             {:ok, path} <- DescriptorStore.put(:overrides, attrs) do
          {:ok,
           %{
             message:
               "override #{action_name} -> #{path}; edit this YAML and run `mix allbert.intent reindex` to apply",
             status: :completed,
             path: path,
             descriptor: %{app_id: descriptor.app_id, action_name: descriptor.action_name}
           }}
        else
          {:error, failures} when is_list(failures) ->
            {:ok,
             rejected("could not edit #{action_name}: gate failed #{inspect(failures)}", failures)}

          {:error, reason} ->
            {:ok, rejected("could not edit #{action_name}: #{inspect(reason)}", reason)}
        end
    end
  end

  def disable(action_name) do
    app_id = descriptor_app_id(action_name)

    with :ok <- Gate.check_removal(app_id, action_name),
         {:ok, path} <-
           DescriptorStore.put(:overrides, %{
             app_id: app_id,
             action_name: action_name,
             disabled: true
           }) do
      {:ok,
       %{
         message: "disabled #{action_name} (#{path}); run `mix allbert.intent reindex` to apply",
         status: :completed,
         path: path,
         descriptor: %{app_id: app_id, action_name: action_name}
       }}
    else
      {:error, failures} when is_list(failures) ->
        {:ok,
         rejected("could not disable #{action_name}: gate failed #{inspect(failures)}", failures)}

      {:error, reason} ->
        {:ok, rejected("could not disable #{action_name}: #{inspect(reason)}", reason)}
    end
  end

  @spec enable(String.t()) :: {:ok, map()}
  def enable(action_name) do
    app_id = descriptor_app_id(action_name)
    descriptors = DescriptorResolver.resolve(ignore_disabled?: true)

    with :ok <- Gate.check_descriptors(descriptors),
         {:ok, path} <- DescriptorStore.delete(:overrides, app_id, action_name) do
      {:ok,
       %{
         message:
           "enabled #{action_name} (removed override #{path}); run `mix allbert.intent reindex` to apply",
         status: :completed,
         path: path,
         descriptor: %{app_id: app_id, action_name: action_name}
       }}
    else
      {:error, failures} when is_list(failures) ->
        {:ok,
         rejected("could not enable #{action_name}: gate failed #{inspect(failures)}", failures)}

      {:error, reason} ->
        {:ok, rejected("could not enable #{action_name}: #{inspect(reason)}", reason)}
    end
  end

  @spec promote(String.t(), map()) :: {:ok, map()}
  def promote(action_name, params \\ %{}) do
    from = tier_option(field(params, :from), :review)
    to = tier_option(field(params, :to), :generated)
    app_id = descriptor_app_id(action_name)

    with {:ok, attrs} <- promotion_attrs(from, app_id, action_name),
         :ok <- Gate.check_promotion(attrs),
         {:ok, path} <- DescriptorStore.promote(from, to, to_string(app_id), action_name) do
      {:ok,
       %{
         message: "promoted #{action_name} -> #{path}; run `mix allbert.intent reindex` to apply",
         status: :completed,
         path: path,
         descriptor: %{app_id: app_id, action_name: action_name, from: from, to: to}
       }}
    else
      {:error, failures} when is_list(failures) ->
        {:ok,
         rejected("could not promote #{action_name}: gate failed #{inspect(failures)}", failures)}

      {:error, reason} ->
        {:ok, rejected("could not promote #{action_name}: #{inspect(reason)}", reason)}
    end
  end

  @spec baseline(map()) :: {:ok, map()}
  def baseline(params \\ %{}) do
    id = field(params, :id, "v056-current-baseline")

    with {:ok, cases} <- Corpus.load(),
         run <- Runner.run(cases),
         score <- Scorer.score(run, nil),
         baseline <- baseline_attrs(id, cases, score),
         {:ok, path} <- baseline_path(params),
         :ok <- write_yaml_atomic(path, baseline) do
      {:ok,
       %{
         message:
           "intent eval baseline id=#{id} cases=#{length(cases)} accuracy=#{score.overall_accuracy} -> #{path}",
         status: :completed,
         path: path,
         baseline: baseline
       }}
    else
      {:error, reason} ->
        {:ok, rejected("could not write intent eval baseline: #{inspect(reason)}", reason)}
    end
  end

  @spec capture(map()) :: {:ok, map()}
  def capture(params) do
    redacted = params |> capture_attrs() |> Redactor.redact(:traces)

    with {:ok, case} <- Corpus.validate(redacted),
         {:ok, file} <- capture_path(case.id),
         payload <- case_payload(case, redacted),
         :ok <- write_yaml_atomic(file, payload) do
      {:ok,
       %{
         message: "captured intent eval case #{case.id} -> #{file}",
         status: :completed,
         path: file,
         eval_case: payload
       }}
    else
      {:error, reason} ->
        {:ok, rejected("could not capture intent eval case: #{inspect(reason)}", reason)}
    end
  end

  @spec add_capture(map()) :: {:ok, map()}
  def add_capture(params) do
    force? = truthy?(field(params, :force, false))

    with {:ok, source} <- captured_source(params),
         {:ok, attrs} <- YamlCodec.read_file(source),
         {:ok, case} <- Corpus.validate(attrs),
         {:ok, dest} <- fixture_case_path(params, case),
         :ok <- ensure_new_or_forced(dest, force?),
         payload <- case_payload(case, attrs),
         :ok <- write_yaml_atomic(dest, payload) do
      {:ok,
       %{
         message: "added intent eval case #{case.id} -> #{dest}",
         status: :completed,
         path: dest,
         source_path: source,
         eval_case: payload
       }}
    else
      {:error, reason} ->
        {:ok, rejected("could not add intent eval case: #{inspect(reason)}", reason)}
    end
  end

  def tier_option(nil, default), do: default
  def tier_option("learned", _default), do: :review
  def tier_option("learned-review", _default), do: :review
  def tier_option("review", _default), do: :review
  def tier_option("generated", _default), do: :generated
  def tier_option("overrides", _default), do: :overrides
  def tier_option("override", _default), do: :overrides
  def tier_option(value, _default) when is_atom(value), do: value
  def tier_option(_value, default), do: default

  defp strategy(params) do
    cond do
      truthy?(field(params, :heuristic, false)) -> :heuristic
      field(params, :strategy) in ["heuristic", :heuristic] -> :heuristic
      true -> :model
    end
  end

  defp descriptor_for_action(action_name) do
    Enum.find(DescriptorResolver.resolve(), &(&1.action_name == action_name))
  end

  defp descriptor_app_id(action_name) do
    case ActionsRegistry.capability(action_name) do
      {:ok, capability} -> capability.app_id || :allbert
      _other -> :allbert
    end
  end

  defp promotion_attrs(tier, app_id, action_name) do
    DescriptorStore.read_attrs(tier)
    |> Enum.find(fn attrs ->
      normalize_app_id(field(attrs, :app_id)) == app_id and
        to_string(field(attrs, :action_name)) == action_name
    end)
    |> case do
      nil -> {:error, :not_found}
      attrs -> {:ok, attrs}
    end
  end

  defp override_attrs(descriptor) do
    %{
      app_id: descriptor.app_id,
      action_name: descriptor.action_name,
      label: descriptor.label,
      destination: descriptor.destination,
      examples: descriptor.examples,
      synonyms: descriptor.synonyms,
      required_slots: descriptor.required_slots,
      optional_slots: descriptor.optional_slots,
      slot_extractors: descriptor.slot_extractors,
      vocabulary: descriptor.vocabulary,
      handoff_required?: descriptor.handoff_required?,
      disabled: false
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, [], %{}] end)
    |> Map.new()
  end

  defp baseline_attrs(id, cases, score) do
    score
    |> Map.drop([:gate])
    |> Map.merge(%{
      id: id,
      schema_version: 1,
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      corpus_case_count: length(cases),
      gate: %{status: gate_status(score), failures: gate_failures(score)}
    })
    |> stringify_data()
  end

  defp gate_status(score) do
    case Gate.check(score, nil) do
      :ok -> :pass
      {:error, _failures} -> :fail
    end
  end

  defp gate_failures(score) do
    case Gate.check(score, nil) do
      :ok -> []
      {:error, failures} -> failures
    end
  end

  defp capture_attrs(params) do
    case field(params, :case) do
      %{} = attrs ->
        attrs

      _other ->
        source_ref = field(params, :source_ref) || field(params, :ref)
        utterance = field(params, :utterance) || source_ref
        id = field(params, :id) || generated_case_id(utterance || inspect(params))

        %{
          schema_version: 1,
          id: id,
          domain: field(params, :domain, "captured"),
          surface: field(params, :surface, "any"),
          utterance: utterance,
          context: field(params, :context, %{}),
          expected: expected_attrs(params),
          negative: truthy?(field(params, :negative, false)),
          holdout: truthy?(field(params, :holdout, false)),
          rationale: field(params, :rationale),
          source_ref: source_ref
        }
    end
  end

  defp expected_attrs(params) do
    case field(params, :expected) do
      %{} = expected ->
        expected

      _other ->
        %{
          kind: field(params, :kind, "none"),
          action: field(params, :action),
          slots: field(params, :slots, %{})
        }
        |> Enum.reject(fn {_key, value} -> value in [nil, %{}] end)
        |> Map.new()
    end
  end

  defp case_payload(case, attrs) do
    %{
      schema_version: 1,
      id: case.id,
      domain: case.domain,
      surface: to_string(case.surface),
      utterance: case.utterance,
      context: case.context,
      expected: case.expected,
      negative: case.negative?,
      holdout: case.holdout?,
      rationale: case.rationale
    }
    |> put_if_present(:source_ref, field(attrs, :source_ref))
    |> stringify_data()
  end

  defp generated_case_id(seed) do
    digest =
      seed
      |> to_string()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "captured-#{digest}"
  end

  defp baseline_path(params) do
    with {:ok, root} <- fixture_root(params) do
      {:ok, Path.join(root, "baseline.yaml")}
    end
  end

  defp captured_source(params) do
    cond do
      is_binary(field(params, :path)) ->
        safe_captured_file(field(params, :path))

      is_binary(field(params, :id)) ->
        capture_path(field(params, :id))

      true ->
        {:error, :missing_capture_id}
    end
  end

  defp capture_path(id) do
    with {:ok, id} <- safe_component(id, :id) do
      {:ok, Path.join(captured_root(), "#{id}.yaml")}
    end
  end

  defp captured_root, do: Path.join([Paths.home(), "intents", "eval", "captured"])

  defp fixture_case_path(params, case) do
    with {:ok, root} <- fixture_root(params),
         {:ok, domain} <- safe_component(case.domain, :domain),
         {:ok, id} <- safe_component(case.id, :id) do
      {:ok, Path.join([root, domain, "#{id}.yaml"])}
    end
  end

  defp fixture_root(params) do
    root =
      field(params, :fixture_root) ||
        Enum.find(@fixture_candidates, &File.dir?/1) ||
        hd(@fixture_candidates)

    root = Path.expand(root)
    cwd = File.cwd!()

    if under_root?(root, cwd) do
      {:ok, root}
    else
      {:error, {:unsafe_fixture_root, root}}
    end
  end

  defp safe_captured_file(path) do
    root = Path.expand(captured_root())
    path = Path.expand(path)

    cond do
      not under_root?(path, root) ->
        {:error, :unsafe_capture_path}

      Path.extname(path) not in [".yaml", ".yml"] ->
        {:error, :unsafe_capture_path}

      true ->
        {:ok, path}
    end
  end

  defp ensure_new_or_forced(path, true), do: safe_write_target(path)

  defp ensure_new_or_forced(path, false) do
    if File.exists?(path), do: {:error, :already_exists}, else: safe_write_target(path)
  end

  defp safe_write_target(path) do
    if Path.extname(path) in [".yaml", ".yml"], do: :ok, else: {:error, :unsafe_path}
  end

  defp write_yaml_atomic(path, map) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      yaml = YamlCodec.encode!(map)
      tmp = "#{path}.tmp-#{System.unique_integer([:positive])}"

      with :ok <- File.write(tmp, yaml),
           :ok <- File.rename(tmp, path) do
        :ok
      else
        {:error, reason} ->
          _ = File.rm(tmp)
          {:error, reason}
      end
    end
  end

  defp safe_component(value, field_name) when is_atom(value),
    do: value |> Atom.to_string() |> safe_component(field_name)

  defp safe_component(value, field_name) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(@safe_component, value) do
      {:ok, value}
    else
      {:error, {:invalid_component, field_name, value}}
    end
  end

  defp safe_component(value, field_name), do: {:error, {:invalid_component, field_name, value}}

  defp under_root?(path, root) do
    path = Path.expand(path)
    root = Path.expand(root)
    path == root or String.starts_with?(path, root <> "/")
  end

  defp normalize_app_id(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp normalize_app_id(value), do: value

  defp rejected(message, reason) do
    %{message: message, status: :rejected, error: reason}
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false

  defp stringify_data(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), stringify_data(value)} end)
    |> Map.new()
  end

  defp stringify_data(values) when is_list(values), do: Enum.map(values, &stringify_data/1)
  defp stringify_data(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_data(value), do: value

  defp field(map, key, default \\ nil), do: Maps.field(map, key, default)
end
