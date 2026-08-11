defmodule AllbertAssist.Pack.ReleaseAssemblyVerifier do
  @moduledoc """
  Verifies the sealed M1.a1 Pack projection in an assembled release tree.

  Verification reads trusted OTP terms, but never starts an Allbert application.
  It emits its machine-readable marker only after every independent projection
  agrees and any applications loaded solely for effective-env checks are
  unloaded again. Descriptor BEAMs are trusted first-party release inputs; this
  verifier is consistency evidence, not a sandbox for hostile code.
  """

  alias AllbertAssist.Licenses
  alias AllbertAssist.Pack.OTPMetadata
  alias AllbertAssist.Pack.Projection

  @checkpoints ~w[v14-m1a1 v14-m1a3]
  @marker_prefix "ALLBERT_RELEASE_ASSEMBLY_V1="
  @manifest_name "THIRD-PARTY-MANIFEST.json"
  @max_manifest_bytes 5_000_000
  @max_descriptor_beam_bytes 10_000_000
  @repository "https://github.com/lexlapax/allbert-assist"
  @applications [:allbert_kernel, :allbert_assist, :allbert_composition, :allbert_assist_web]
  @pack_applications [:allbert_kernel, :allbert_assist]
  # v1.4 M9 extracted :allbert_notes_files into its own umbrella application. It
  # is a genuine first-party pack -- like allbert_kernel/allbert_assist -- and
  # is legitimately loaded in the ambient BEAM performing checkpoint
  # verification (the whole-suite test bootstrap loads it permanently so the
  # compiled action catalog stays contiguous; a packaged release built after
  # M9 carries it on the code path too). It is NOT part of the v14-m1a1/
  # v14-m1a3 checkpoints' own frozen four-application closure (@applications)
  # -- those checkpoints predate the extraction and continue to verify exactly
  # that shape, so it must not be added to @applications or @pack_applications.
  # validate_unexpected_loaded_pack_applications!/0 exists to catch an UNKNOWN
  # pack-declaring application slipping into the ambient state; a known,
  # reviewed, first-party extracted pack outside this checkpoint's own closure
  # is not that threat. M12 extracts two more packs -- add each new pack atom
  # here (not to @pack_applications/@applications) unless/until this file's
  # checkpoints are bumped to include them in the verified closure itself.
  @known_extracted_pack_applications [:allbert_notes_files]
  @component_ids %{
    allbert_kernel: "beam-allbert-kernel",
    allbert_assist: "beam-allbert-assist",
    allbert_composition: "beam-allbert-composition",
    allbert_assist_web: "beam-allbert-assist-web"
  }
  @pack_modules %{
    allbert_kernel: AllbertAssist.Pack.Kernel,
    allbert_assist: AllbertAssist.Pack.Residual,
    allbert_composition: nil,
    allbert_assist_web: nil
  }
  @composition_modules [
    AllbertAssist.Pack.CompositionCoordinator,
    AllbertAssist.Pack.ProductBootstrap,
    AllbertAssist.Pack.ProductCLI
  ]
  @default_launcher_target "AllbertAssist.Pack.ProductCLI.main(System.argv())"
  @max_overlay_bytes 1_000_000
  @dependencies %{
    allbert_kernel: [],
    allbert_assist: [:allbert_kernel],
    allbert_composition: [:allbert_kernel, :allbert_assist],
    allbert_assist_web: [:allbert_assist, :allbert_composition]
  }
  @descriptor_application_effect_mfas [
    {Application, :start, 1},
    {Application, :start, 2},
    {Application, :ensure_all_started, 1},
    {Application, :ensure_all_started, 2},
    {Application, :stop, 1},
    {Application, :load, 1},
    {Application, :unload, 1},
    {Application, :put_env, 3},
    {Application, :put_env, 4},
    {Application, :delete_env, 2},
    {Application, :delete_env, 3},
    {:application, :start, 1},
    {:application, :start, 2},
    {:application, :ensure_all_started, 1},
    {:application, :ensure_all_started, 2},
    {:application, :ensure_all_started, 3},
    {:application, :stop, 1},
    {:application, :load, 1},
    {:application, :load, 2},
    {:application, :unload, 1},
    {:application, :set_env, 1},
    {:application, :set_env, 2},
    {:application, :set_env, 3},
    {:application, :set_env, 4},
    {:application, :unset_env, 2},
    {:application, :unset_env, 3},
    {:application_controller, :start_application, 2},
    {:application_controller, :start_application_request, 2},
    {:application_controller, :stop_application, 1},
    {:application_controller, :stop_application_request, 1},
    {:application_controller, :load_application, 1},
    {:application_controller, :unload_application, 1},
    {:application_controller, :set_env, 2},
    {:application_controller, :set_env, 3},
    {:application_controller, :set_env, 4},
    {:application_controller, :unset_env, 2},
    {:application_controller, :unset_env, 3}
  ]

  @spec verify!(Path.t(), String.t()) :: :ok
  def verify!(release_root, checkpoint)
      when is_binary(release_root) and is_binary(checkpoint) do
    verify_release!(release_root, checkpoint, true)
  end

  def verify!(_release_root, checkpoint) do
    raise ArgumentError,
          "unsupported release-assembly checkpoint: #{inspect(checkpoint)}"
  end

  if Mix.env() == :test do
    @doc false
    def verify_fixture!(release_root, checkpoint)
        when is_binary(release_root) and is_binary(checkpoint) do
      verify_release!(release_root, checkpoint, false)
    end
  end

  defp verify_release!(release_root, checkpoint, require_clean_start?) do
    unless checkpoint in @checkpoints,
      do: raise(ArgumentError, "unsupported release-assembly checkpoint: #{inspect(checkpoint)}")

    if require_clean_start?, do: validate_no_started_allbert_applications!()

    root = validate_release_root!(release_root)
    rel_path = find_single_rel!(root)
    release = OTPMetadata.read_rel(rel_path) |> value!(:rel)
    release_applications = validate_release!(root, rel_path, release)
    snapshot = application_state_snapshot(release_applications)

    marker =
      try do
        verify_marker!(
          root,
          checkpoint,
          release,
          release_applications,
          require_clean_start?,
          snapshot
        )
      after
        restore_application_state!(snapshot)
      end

    encoded = marker |> Licenses.canonical_json() |> String.trim_trailing("\n")
    IO.puts(@marker_prefix <> encoded)
    :ok
  end

  defp verify_marker!(
         root,
         checkpoint,
         release,
         release_applications,
         require_clean_start?,
         snapshot
       ) do
    components = read_manifest_components!(root)
    component_index = validate_first_party_closure!(components)
    applications = read_applications!(root, release_applications, component_index)
    validate_application_metadata!(applications, release_applications)

    guard_descriptor_application_starts!(require_clean_start?, fn ->
      validate_packaged_descriptor_code!(root, applications)
    end)

    if require_clean_start?, do: validate_started_application_state_unchanged!(snapshot)
    validate_unexpected_loaded_pack_applications!()

    projection_applications =
      Enum.filter(applications, &(&1.application in @applications))

    {rows, pack_projection_sha256} =
      with_loaded_pack_applications!(projection_applications, snapshot, fn ->
        validate_descriptorless_effective_env!(applications)

        rows =
          guard_descriptor_application_starts!(require_clean_start?, fn ->
            Projection.reconcile(components, projection_applications, release,
              sealed: true,
              closed_applications: @applications
            )
            |> value!(:pack_projection)
          end)

        digest = Projection.digest(rows) |> value!(:pack_projection_digest)
        {rows, digest}
      end)

    if require_clean_start?, do: validate_started_application_state_unchanged!(snapshot)

    m1a3 =
      if checkpoint == "v14-m1a3" do
        composition = Enum.find(applications, &(&1.application == :allbert_composition))
        residual = Enum.find(applications, &(&1.application == :allbert_assist))

        validate_composition_release!(root, composition)
        validate_residual_composition_boundary!(root, residual)

        %{
          composition_app_sha256: composition.sha256,
          overlay_sha256: validate_default_launcher!(root),
          entrypoint_sha256: sha256(@default_launcher_target)
        }
      end

    build_marker(checkpoint, release, rows, pack_projection_sha256, m1a3)
  end

  defp validate_no_started_allbert_applications! do
    started =
      Application.started_applications()
      |> MapSet.new(&elem(&1, 0))
      |> then(fn started -> Enum.filter(@applications, &MapSet.member?(started, &1)) end)

    unless started == [], do: fail!({:started_allbert_applications, started})
  end

  defp validate_started_application_state_unchanged!(snapshot) do
    actual = %{
      applications: started_applications_snapshot(),
      types: application_start_types_snapshot()
    }

    expected = %{applications: snapshot.started, types: snapshot.started_types}

    unless actual == expected,
      do: fail!({:started_application_state_changed, expected, actual})
  end

  defp guard_descriptor_application_starts!(false, fun), do: fun.()

  defp guard_descriptor_application_starts!(true, fun) do
    parent = self()
    tracer = spawn_link(fn -> descriptor_trace_collector(parent, []) end)
    session = :trace.session_create(:allbert_release_descriptor_guard, tracer, [])

    try do
      :trace.process(session, :existing, true, [:call])
      :trace.process(session, :new, true, [:call])

      Enum.each(@descriptor_application_effect_mfas, fn mfa ->
        unless :trace.function(session, mfa, [], []) == 1,
          do: fail!({:descriptor_trace_function, mfa})
      end)

      result = fun.()
      effects = finish_descriptor_trace!(tracer, session)

      unless effects == [], do: fail!({:descriptor_application_effect, effects})
      result
    after
      :trace.session_destroy(session)
      send(tracer, :stop)
    end
  end

  defp descriptor_trace_collector(parent, effects) do
    receive do
      {:trace, _pid, :call, {module, function, arguments}} ->
        effect = {module, function, length(arguments), List.first(arguments)}
        descriptor_trace_collector(parent, [effect | effects])

      {:finish, ^parent, session, reference} ->
        delivered = :trace.delivered(session, :all)

        receive do
          {:trace_delivered, :all, ^delivered} -> :ok
        after
          5_000 -> exit(:descriptor_trace_delivery_timeout)
        end

        effects = drain_descriptor_trace_messages(effects)
        send(parent, {:descriptor_trace_finished, reference, Enum.reverse(effects)})
        descriptor_trace_collector(parent, [])

      :stop ->
        :ok
    end
  end

  defp drain_descriptor_trace_messages(effects) do
    receive do
      {:trace, _pid, :call, {module, function, arguments}} ->
        effect = {module, function, length(arguments), List.first(arguments)}
        drain_descriptor_trace_messages([effect | effects])
    after
      0 -> effects
    end
  end

  defp finish_descriptor_trace!(tracer, session) do
    reference = make_ref()
    send(tracer, {:finish, self(), session, reference})

    receive do
      {:descriptor_trace_finished, ^reference, effects} -> effects
    after
      5_000 -> fail!(:descriptor_trace_timeout)
    end
  end

  defp validate_release_root!(root) do
    root = Path.expand(root)

    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory}} -> root
      _other -> fail!({:invalid_release_root, root})
    end
  end

  defp find_single_rel!(root) do
    paths = Path.wildcard(Path.join([root, "releases", "*", "*.rel"]), match_dot: true)

    case paths do
      [path] ->
        ensure_regular_release_file!(root, path, :rel)

        if Path.basename(path) == "allbert.rel",
          do: path,
          else: fail!({:unexpected_rel, Path.basename(path)})

      _paths ->
        fail!({:rel_closure, length(paths)})
    end
  end

  defp validate_release!(root, rel_path, release) do
    expected_path = Path.join([root, "releases", release.version, "allbert.rel"])

    unless release.name == "allbert" and Path.expand(rel_path) == Path.expand(expected_path),
      do: fail!(:release_identity)

    allbert_applications =
      Enum.filter(release.applications, &allbert_application?(&1.application))

    unless Enum.map(allbert_applications, & &1.application) == @applications,
      do: fail!({:application_order, Enum.map(allbert_applications, & &1.application)})

    Enum.each(allbert_applications, fn application ->
      unless application.version == release.version,
        do: fail!({:release_version_mismatch, application.application})

      unless application.start_mode == :permanent,
        do: fail!({:non_permanent_application, application.application})

      unless application.included_applications == [],
        do: fail!({:included_applications, application.application})
    end)

    release.applications
  end

  defp read_manifest_components!(root) do
    path = Path.join(root, @manifest_name)
    ensure_regular_release_file!(root, path, :manifest)

    manifest =
      path
      |> read_bounded_file!(@max_manifest_bytes, :manifest)
      |> Jason.decode()
      |> value!(:manifest_json)

    case manifest do
      %{"schema_version" => 1, "components" => components} when is_list(components) ->
        components

      _other ->
        fail!(:manifest_shape)
    end
  end

  defp validate_first_party_closure!(components) do
    Enum.each(components, &validate_manifest_component_shape!/1)

    first_party =
      Enum.filter(components, fn
        %{"kind" => "beam_app", "provenance" => %{"ecosystem" => "allbert"}} -> true
        _component -> false
      end)

    applications = Enum.map(first_party, & &1["application"])

    unless length(applications) == length(Enum.uniq(applications)),
      do: fail!(:duplicate_first_party_application)

    unless Enum.sort(applications) == Enum.sort(Enum.map(@applications, &Atom.to_string/1)),
      do: fail!({:first_party_closure, applications})

    index = Map.new(first_party, &{&1["application"], &1})

    Enum.each(@applications, fn application ->
      name = Atom.to_string(application)
      component = Map.fetch!(index, name)

      unless component["id"] == Map.fetch!(@component_ids, application),
        do: fail!({:component_id, application})

      unless component["provenance"] == %{
               "ecosystem" => "allbert",
               "repository" => @repository
             },
             do: fail!({:first_party_provenance, application})
    end)

    validate_canonical_pack_rows!(components, index)

    index
  end

  defp validate_manifest_component_shape!(%{"pack" => pack}) when not is_map(pack),
    do: fail!({:malformed_pack, pack})

  defp validate_manifest_component_shape!(component) when is_map(component), do: :ok
  defp validate_manifest_component_shape!(_component), do: fail!(:manifest_component_shape)

  defp validate_canonical_pack_rows!(components, first_party_index) do
    Enum.each(@applications, fn application ->
      component = Map.fetch!(first_party_index, Atom.to_string(application))

      case {Map.fetch!(@pack_modules, application), Map.fetch(component, "pack")} do
        {module, {:ok, pack}} when not is_nil(module) and is_map(pack) -> :ok
        {nil, :error} -> :ok
        {_expected, actual} -> fail!({:canonical_pack_declaration, application, actual})
      end
    end)

    Enum.each(components, &validate_pack_component_owner!(&1, first_party_index))
  end

  defp validate_pack_component_owner!(%{"pack" => _pack} = component, first_party_index) do
    canonical = Map.get(first_party_index, component["application"])

    unless canonical == component,
      do: fail!({:pack_component_owner, component["application"], component["id"]})
  end

  defp validate_pack_component_owner!(_component, _first_party_index), do: :ok

  defp read_applications!(root, release_applications, component_index) do
    expected_paths =
      Map.new(release_applications, fn release_application ->
        application = release_application.application
        {application, application_path(root, application, release_application.version)}
      end)

    actual_paths =
      root
      |> Path.join("lib/*/ebin/*.app")
      |> Path.wildcard(match_dot: true)
      |> Enum.map(&Path.expand/1)
      |> Enum.sort()

    unless actual_paths ==
             expected_paths |> Map.values() |> Enum.map(&Path.expand/1) |> Enum.sort(),
           do: fail!({:raw_application_closure, actual_paths})

    Enum.map(release_applications, fn release_application ->
      application = release_application.application
      path = Map.fetch!(expected_paths, application)
      ensure_regular_release_file!(root, path, {:application, application})
      component = Map.get(component_index, Atom.to_string(application))

      spec =
        case component && component["pack"] do
          %{"app_sha256" => sha256} -> OTPMetadata.read_sealed_app(path, sha256)
          nil -> OTPMetadata.read_app(path)
        end
        |> value!({:application, application})

      unless spec.application == application and spec.version == release_application.version,
        do: fail!({:application_identity, application})

      spec
    end)
  end

  defp validate_application_metadata!(applications, release_applications) do
    release_index = Map.new(release_applications, &{&1.application, &1})
    release_set = release_index |> Map.keys() |> MapSet.new()

    Enum.each(applications, fn application ->
      validate_application_metadata_record!(application)
      release_application = Map.fetch!(release_index, application.application)
      validate_application_dependency_closure!(application, release_application, release_set)
    end)
  end

  defp validate_application_metadata_record!(application) do
    case Map.fetch(@pack_modules, application.application) do
      {:ok, expected_module} ->
        unless application.pack_module == expected_module,
          do: fail!({:raw_descriptor, application.application, application.pack_module})

        validate_allbert_application_metadata!(application)

      :error ->
        unless is_nil(application.pack_module),
          do: fail!({:unexpected_raw_pack, application.application, application.pack_module})
    end
  end

  defp validate_allbert_application_metadata!(application) do
    optional_allbert_dependencies =
      application.optional_applications
      |> Enum.filter(&allbert_application?/1)
      |> Enum.sort()

    unless optional_allbert_dependencies == [],
      do:
        fail!(
          {:optional_allbert_dependency, application.application, optional_allbert_dependencies}
        )

    actual_dependencies =
      application.applications
      |> Enum.filter(&allbert_application?/1)
      |> Enum.sort()

    expected_dependencies =
      @dependencies
      |> Map.fetch!(application.application)
      |> Enum.sort()

    unless actual_dependencies == expected_dependencies,
      do:
        fail!(
          {:dependency_dag, application.application, expected_dependencies, actual_dependencies}
        )

    unless application.included_applications == [],
      do: fail!({:raw_included_applications, application.application})
  end

  defp validate_application_dependency_closure!(application, release_application, release_set) do
    missing_required =
      application.applications
      |> Enum.reject(&(&1 in application.optional_applications))
      |> Enum.reject(&MapSet.member?(release_set, &1))
      |> Enum.sort_by(&Atom.to_string/1)

    unless missing_required == [],
      do: fail!({:release_dependency_closure, application.application, missing_required})

    missing_included =
      (application.included_applications ++ release_application.included_applications)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(release_set, &1))
      |> Enum.sort_by(&Atom.to_string/1)

    unless missing_included == [],
      do:
        fail!({:release_included_application_closure, application.application, missing_included})

    unless Enum.sort(application.included_applications) ==
             Enum.sort(release_application.included_applications),
           do:
             fail!(
               {:included_application_mismatch, application.application,
                release_application.included_applications, application.included_applications}
             )
  end

  defp validate_descriptorless_effective_env!(applications) do
    applications
    |> Enum.filter(&is_nil(&1.pack_module))
    |> Enum.each(fn application ->
      OTPMetadata.verify_effective_pack(application)
      |> ok!({:effective_env, application.application})
    end)
  end

  defp validate_unexpected_loaded_pack_applications! do
    known = @pack_applications ++ @known_extracted_pack_applications

    unexpected =
      Application.loaded_applications()
      |> Enum.map(&elem(&1, 0))
      |> Enum.reject(&(&1 in known))
      |> Enum.filter(fn application ->
        match?({:ok, _value}, Application.fetch_env(application, :allbert_pack))
      end)
      |> Enum.sort_by(&Atom.to_string/1)

    unless unexpected == [],
      do: fail!({:unexpected_loaded_pack_applications, unexpected})
  end

  defp validate_packaged_descriptor_code!(root, applications) do
    applications
    |> Enum.reject(&is_nil(&1.pack_module))
    |> Enum.each(&validate_packaged_descriptor_record!(root, &1))
  end

  defp validate_packaged_descriptor_record!(root, application) do
    module = application.pack_module
    expected_path = Path.join(Path.dirname(application.path), "#{module}.beam")

    ensure_regular_release_file!(
      root,
      expected_path,
      {:descriptor_beam, application.application}
    )

    bytes = read_bounded_file!(expected_path, @max_descriptor_beam_bytes, :descriptor_beam)
    validate_exact_beam_container!(application, bytes)
    validate_packaged_descriptor_candidate!(application, expected_path, bytes)
    load_exact_packaged_descriptor!(application, expected_path, bytes)
    validate_loaded_descriptor!(application, expected_path, bytes)
  end

  defp load_exact_packaged_descriptor!(application, expected_path, bytes) do
    module = application.pack_module

    case :code.load_binary(module, String.to_charlist(expected_path), bytes) do
      {:module, ^module} -> :ok
      {:error, reason} -> fail!({:descriptor_beam_load, application.application, reason})
    end
  end

  defp validate_packaged_descriptor_candidate!(application, expected_path, bytes) do
    module = application.pack_module
    available_path = module |> :code.which() |> expanded_code_path()

    unless available_path == Path.expand(expected_path),
      do: fail!({:descriptor_beam_origin, application.application, available_path})

    case {:code.get_object_code(module), :beam_lib.md5(bytes)} do
      {{^module, ^bytes, object_path}, {:ok, {^module, _md5}}} ->
        unless expanded_code_path(object_path) == Path.expand(expected_path),
          do: fail!({:descriptor_beam_origin, application.application, object_path})

      _other ->
        fail!({:descriptor_beam_bytes, application.application})
    end
  end

  defp validate_loaded_descriptor!(application, expected_path, bytes) do
    module = application.pack_module
    loaded_path = module |> :code.which() |> expanded_code_path()

    unless loaded_path == Path.expand(expected_path),
      do: fail!({:descriptor_beam_origin, application.application, loaded_path})

    case {:code.get_object_code(module), :beam_lib.md5(bytes)} do
      {{^module, ^bytes, object_path}, {:ok, {^module, md5}}} ->
        unless expanded_code_path(object_path) == Path.expand(expected_path),
          do: fail!({:descriptor_beam_origin, application.application, object_path})

        unless module.module_info(:md5) == md5,
          do: fail!({:descriptor_beam_loaded_bytes, application.application})

      _other ->
        fail!({:descriptor_beam_bytes, application.application})
    end
  end

  defp validate_exact_beam_container!(application, bytes) do
    case bytes do
      <<"FOR1", declared_size::unsigned-big-integer-size(32), "BEAM", _chunks::binary>>
      when declared_size + 8 == byte_size(bytes) ->
        :ok

      _other ->
        fail!({:descriptor_beam_container, application.application})
    end
  end

  defp expanded_code_path(path) when is_list(path) or is_binary(path),
    do: path |> to_string() |> Path.expand()

  defp expanded_code_path(path), do: path

  defp read_bounded_file!(path, max_bytes, label) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= max_bytes ->
        case File.read(path) do
          {:ok, bytes} when byte_size(bytes) <= max_bytes -> bytes
          {:ok, bytes} -> fail!({:too_large, label, byte_size(bytes)})
          {:error, reason} -> fail!({:read, label, reason})
        end

      {:ok, %File.Stat{type: :regular, size: size}} ->
        fail!({:too_large, label, size})

      {:ok, %File.Stat{type: type}} ->
        fail!({:not_regular, label, type})

      {:error, reason} ->
        fail!({:stat, label, reason})
    end
  end

  defp with_loaded_pack_applications!(applications, snapshot, fun) do
    pack_applications = Enum.reject(applications, &is_nil(&1.pack_module))

    unless Enum.map(pack_applications, & &1.application) == @pack_applications,
      do: fail!({:pack_application_order, Enum.map(pack_applications, & &1.application)})

    load_sealed_pack_applications!(pack_applications, snapshot)
    fun.()
  end

  defp application_state_snapshot(release_applications) do
    loaded_records = Application.loaded_applications()
    started_records = Application.started_applications()
    loaded = application_records_snapshot(loaded_records)
    started = application_records_snapshot(started_records)
    started_types = application_start_types_snapshot()
    environment = application_environment_snapshot()
    release_order = Enum.map(release_applications, & &1.application)

    tracked_applications =
      loaded
      |> Map.keys()
      |> Kernel.++(release_order)
      |> Kernel.++(Map.keys(environment))
      |> Enum.uniq()
      |> Enum.sort_by(&Atom.to_string/1)

    applications =
      Map.new(tracked_applications, fn application ->
        {application,
         %{
           loaded?: Map.has_key?(loaded, application),
           started?: Map.has_key?(started, application),
           spec: Application.spec(application),
           env: Application.get_all_env(application)
         }}
      end)

    %{
      loaded: loaded,
      loaded_order: Enum.map(loaded_records, &elem(&1, 0)),
      started: started,
      started_order: Enum.map(started_records, &elem(&1, 0)),
      started_types: started_types,
      release_order: release_order,
      environment: environment,
      applications: applications
    }
  end

  defp load_sealed_pack_applications!(applications, snapshot) do
    applications
    |> Enum.reverse()
    |> Enum.each(fn application ->
      state = Map.fetch!(snapshot.applications, application.application)

      if state.loaded? and not state.started?,
        do: unload_application!(application.application)
    end)

    Enum.each(applications, fn application ->
      state = Map.fetch!(snapshot.applications, application.application)

      if state.started? do
        validate_loaded_application!(application)
      else
        load_sealed_application!(application)
        apply_effective_env!(application.application, state.env)
        validate_loaded_application!(application)
      end
    end)
  end

  defp load_sealed_application!(application) do
    case :application.load(application.raw_spec) do
      :ok -> :ok
      {:error, reason} -> fail!({:application_load, application.application, reason})
    end
  end

  defp validate_loaded_application!(application) do
    loaded_version = Application.spec(application.application, :vsn)

    unless loaded_version && to_string(loaded_version) == application.version,
      do: fail!({:loaded_application_version, application.application, loaded_version})
  end

  defp restore_application_state!(snapshot) do
    stop_newly_started_applications!(snapshot)
    stop_changed_start_type_applications!(snapshot)

    @pack_applications
    |> Enum.reverse()
    |> Enum.each(fn application ->
      state = Map.fetch!(snapshot.applications, application)
      restore_unstarted_application!(application, state)
    end)

    unload_newly_loaded_applications!(snapshot)
    restore_missing_loaded_applications!(snapshot)
    restore_missing_started_applications!(snapshot)

    restore_application_environments!(snapshot)

    assert_application_state_restored!(snapshot)
  end

  defp restore_unstarted_application!(_application, %{started?: true}), do: :ok

  defp restore_unstarted_application!(application, _state) do
    if Map.has_key?(loaded_applications_snapshot(), application),
      do: unload_application!(application)
  end

  defp stop_newly_started_applications!(snapshot) do
    Application.started_applications()
    |> Enum.map(&elem(&1, 0))
    |> Enum.reject(&Map.has_key?(snapshot.started, &1))
    |> Enum.each(fn application ->
      case Application.stop(application) do
        :ok -> :ok
        {:error, reason} -> fail!({:application_stop, application, reason})
      end
    end)
  end

  defp stop_changed_start_type_applications!(snapshot) do
    current_types = application_start_types_snapshot()

    snapshot.started_types
    |> Enum.filter(fn {application, expected_type} ->
      match?(
        {:ok, actual_type} when actual_type != expected_type,
        Map.fetch(current_types, application)
      )
    end)
    |> Enum.each(fn {application, _expected_type} ->
      case Application.stop(application) do
        :ok -> :ok
        {:error, reason} -> fail!({:application_stop_for_type_restore, application, reason})
      end
    end)
  end

  defp unload_newly_loaded_applications!(snapshot) do
    Application.loaded_applications()
    |> Enum.map(&elem(&1, 0))
    |> Enum.reject(&Map.has_key?(snapshot.loaded, &1))
    |> Enum.each(&unload_application!/1)
  end

  defp restore_missing_loaded_applications!(snapshot) do
    Enum.each(Enum.reverse(snapshot.loaded_order), fn application ->
      unless Map.has_key?(loaded_applications_snapshot(), application) do
        state = Map.fetch!(snapshot.applications, application)
        restore_loaded_application!(application, state)
      end
    end)
  end

  defp restore_missing_started_applications!(snapshot) do
    Enum.each(Enum.reverse(snapshot.started_order), fn application ->
      unless Map.has_key?(started_applications_snapshot(), application),
        do: restore_started_application!(application, snapshot)
    end)
  end

  defp restore_started_application!(application, snapshot) do
    start_type = Map.fetch!(snapshot.started_types, application)

    case Application.start(application, start_type) do
      :ok -> :ok
      {:error, reason} -> fail!({:application_start_restore, application, reason})
    end
  end

  defp restore_loaded_application!(application, state) do
    raw_spec =
      {:application, application,
       state.spec
       |> Keyword.put(:env, state.env)}

    case :application.load(raw_spec) do
      :ok -> :ok
      {:error, reason} -> fail!({:application_restore, application, reason})
    end
  end

  defp restore_effective_env!(application, expected) do
    expected = Map.new(expected)
    current = Application.get_all_env(application)

    unless Map.new(current) == expected do
      expected_keys = Map.keys(expected)

      current
      |> Keyword.keys()
      |> Enum.reject(&(&1 in expected_keys))
      |> Enum.each(&Application.delete_env(application, &1))

      apply_effective_env!(application, Map.to_list(expected))
    end
  end

  defp restore_application_environments!(snapshot) do
    applications =
      snapshot.environment
      |> Map.keys()
      |> Kernel.++(application_environment_snapshot() |> Map.keys())
      |> Kernel.++(Map.keys(snapshot.applications))
      |> Enum.uniq()
      |> Enum.sort_by(&Atom.to_string/1)

    Enum.each(applications, fn application ->
      restore_effective_env!(application, Map.get(snapshot.environment, application, %{}))
    end)
  end

  defp apply_effective_env!(application, env) do
    Enum.each(env, fn {key, value} -> Application.put_env(application, key, value) end)
  end

  defp unload_application!(application) do
    case Application.unload(application) do
      :ok -> :ok
      {:error, reason} -> fail!({:application_unload, application, reason})
    end
  end

  defp assert_application_state_restored!(snapshot) do
    actual = %{
      loaded: loaded_applications_snapshot(),
      started: started_applications_snapshot(),
      started_types: application_start_types_snapshot(),
      environment: application_environment_snapshot()
    }

    unless actual.loaded == snapshot.loaded,
      do: fail!({:loaded_application_state, snapshot.loaded, actual.loaded})

    unless actual.started == snapshot.started,
      do: fail!({:started_application_state, snapshot.started, actual.started})

    unless actual.started_types == snapshot.started_types,
      do: fail!({:started_application_type_state, snapshot.started_types, actual.started_types})

    unless actual.environment == snapshot.environment do
      changed =
        actual.environment
        |> Map.keys()
        |> Kernel.++(Map.keys(snapshot.environment))
        |> Enum.uniq()
        |> Enum.filter(
          &(Map.get(actual.environment, &1, %{}) != Map.get(snapshot.environment, &1, %{}))
        )
        |> Enum.sort_by(&Atom.to_string/1)

      fail!({:application_env_state, changed})
    end
  end

  defp loaded_applications_snapshot do
    Application.loaded_applications() |> application_records_snapshot()
  end

  defp started_applications_snapshot do
    Application.started_applications() |> application_records_snapshot()
  end

  defp application_start_types_snapshot do
    :application_controller.info()
    |> Keyword.fetch!(:started)
    |> Map.new()
  rescue
    _error -> fail!(:application_start_types_snapshot)
  end

  defp application_records_snapshot(records) do
    records
    |> Map.new(fn {application, description, version} ->
      {application, {description, version}}
    end)
  end

  defp application_environment_snapshot do
    :ac_tab
    |> :ets.tab2list()
    |> Enum.reduce(%{}, fn
      {{:env, application, _key}, _value}, snapshot ->
        Map.put_new_lazy(snapshot, application, fn ->
          application |> Application.get_all_env() |> Map.new()
        end)

      _record, snapshot ->
        snapshot
    end)
  rescue
    _error -> fail!(:application_environment_snapshot)
  end

  defp validate_composition_release!(root, composition) do
    missing_modules = @composition_modules -- composition.modules

    unless missing_modules == [],
      do: fail!({:composition_modules, missing_modules})

    Enum.each(@composition_modules, fn module ->
      path = Path.join(Path.dirname(composition.path), "#{module}.beam")
      ensure_regular_release_file!(root, path, {:composition_beam, module})
      validate_beam_module!(path, module, :composition_beam)
    end)
  end

  defp validate_residual_composition_boundary!(root, residual) do
    owned_modules = Enum.filter(residual.modules, &(&1 in @composition_modules))

    unless owned_modules == [],
      do: fail!({:residual_composition_modules, owned_modules})

    Enum.each(residual.modules, fn module ->
      path = Path.join(Path.dirname(residual.path), "#{module}.beam")
      ensure_regular_release_file!(root, path, {:residual_beam, module})
      validate_beam_module!(path, module, :residual_beam)

      imports =
        case :beam_lib.chunks(String.to_charlist(path), [:imports]) do
          {:ok, {^module, [imports: imports]}} when is_list(imports) -> imports
          _other -> fail!({:residual_beam_imports, module})
        end

      upward_references =
        Enum.filter(imports, fn
          {target, _function, _arity} -> target in @composition_modules
          _other -> false
        end)

      unless upward_references == [],
        do: fail!({:residual_composition_reference, module, upward_references})
    end)
  end

  defp validate_beam_module!(path, module, label) do
    case :beam_lib.chunks(String.to_charlist(path), [:exports]) do
      {:ok, {^module, [exports: _exports]}} -> :ok
      _other -> fail!({label, module})
    end
  end

  defp validate_default_launcher!(root) do
    path = Path.join([root, "bin", "allbert"])
    ensure_regular_release_file!(root, path, :default_launcher)
    bytes = read_bounded_file!(path, @max_overlay_bytes, :default_launcher)

    expected = ~s(exec "$RELEASE_BIN" eval "#{@default_launcher_target}" "$@")

    matches =
      bytes
      |> String.split(~r/\R/, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(&1 == expected))

    unless matches == [expected],
      do: fail!({:default_launcher_target, @default_launcher_target})

    sha256(bytes)
  end

  defp build_marker(checkpoint, release, rows, pack_projection_sha256, m1a3) do
    app_sha256 = Map.new(rows, &{Atom.to_string(&1.application), &1.app_sha256})

    app_sha256 =
      case m1a3 do
        %{composition_app_sha256: composition_app_sha256} ->
          Map.put(app_sha256, "allbert_composition", composition_app_sha256)

        nil ->
          app_sha256
      end

    expected_applications =
      if checkpoint == "v14-m1a3",
        do: @pack_applications ++ [:allbert_composition],
        else: @pack_applications

    unless Enum.sort(Map.keys(app_sha256)) ==
             Enum.sort(Enum.map(expected_applications, &Atom.to_string/1)),
           do: fail!({:marker_application_closure, Map.keys(app_sha256)})

    marker = %{
      "schema_version" => 1,
      "status" => "PASS",
      "checkpoint" => checkpoint,
      "rel_sha256" => release.sha256,
      "app_sha256" => app_sha256,
      "pack_projection_sha256" => pack_projection_sha256
    }

    case m1a3 do
      %{overlay_sha256: overlay_sha256, entrypoint_sha256: entrypoint_sha256} ->
        Map.merge(marker, %{
          "overlay_sha256" => overlay_sha256,
          "entrypoint_sha256" => entrypoint_sha256
        })

      nil ->
        marker
    end
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp application_path(root, application, version) do
    Path.join([root, "lib", "#{application}-#{version}", "ebin", "#{application}.app"])
  end

  defp allbert_application?(application) when is_atom(application),
    do: application |> Atom.to_string() |> String.starts_with?("allbert_")

  defp ensure_regular_release_file!(root, path, label) do
    root = Path.expand(root)
    path = Path.expand(path)
    relative = Path.relative_to(path, root)
    parts = Path.split(relative)

    if Path.type(relative) != :relative or parts == [] or hd(parts) == ".." do
      fail!({:unsafe_release_path, label, path})
    end

    parts
    |> Enum.with_index()
    |> Enum.reduce(root, fn {part, index}, parent ->
      candidate = Path.join(parent, part)
      final? = index == length(parts) - 1

      case File.lstat(candidate) do
        {:ok, %File.Stat{type: :regular}} when final? ->
          candidate

        {:ok, %File.Stat{type: :directory}} when not final? ->
          candidate

        {:ok, %File.Stat{type: type}} ->
          fail!({:unsafe_release_path, label, candidate, type})

        {:error, reason} ->
          fail!({:unsafe_release_path, label, candidate, reason})
      end
    end)
  end

  defp value!({:ok, value}, _label), do: value
  defp value!({:error, reason}, label), do: fail!({label, reason})

  defp ok!(:ok, _label), do: :ok
  defp ok!({:error, reason}, label), do: fail!({label, reason})

  @spec fail!(term()) :: no_return()
  defp fail!(reason) do
    raise RuntimeError, "release assembly verification failed: #{inspect(reason)}"
  end
end
