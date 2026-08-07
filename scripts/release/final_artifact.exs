defmodule AllbertAssist.Release.FinalArtifact do
  @moduledoc """
  Deterministic final-artifact composition helpers used by the root Mix release.

  This module is loaded only by `mix.exs`. It owns filesystem composition and
  validation at build time; it is not part of the packaged runtime.
  """

  @manifest_name "cache_manifest.json"
  @digest_file ~r/(?:^|\/)[^\/]+-[0-9a-f]{32}\.[^\/]+$/
  @tracked_logical_gzip_paths ~w[
    images/allbert-mark.svg.gz
    images/allbert-og.svg.gz
    robots.txt.gz
    workspace-offline.html.gz
    workspace-sw.js.gz
  ]
  @generated_logical_gzip_prefixes ["assets/"]
  @gzip_restore_residue ~r/\.gz\.allbert-restore-[1-9][0-9]*\z/
  @openssl_dylib ~r/^lib(?:crypto|ssl)(?:[._-][A-Za-z0-9._-]+)?\.dylib$/
  @catalogued_openssl "libcrypto.3.dylib"
  @catalogued_openssl_loader "@loader_path/libcrypto.3.dylib"
  @exqlite_nif "sqlite3_nif.so"
  @exqlite_install_name "@loader_path/sqlite3_nif.so"
  @linux_sctp_file "libsctp.so.1.0.19"
  @linux_sctp_soname "libsctp.so.1"
  @linux_sctp_package_version "1.0.19+dfsg-2"
  @system_command &System.cmd/3

  @doc false
  def build_web_assets(release, opts \\ []) do
    web_path =
      Keyword.get(opts, :web_path, Path.join([File.cwd!(), "apps", "allbert_assist_web"]))

    web_path = Path.expand(web_path)
    static_root = Path.join(web_path, "priv/static")
    validate_web_asset_boundary!(web_path, static_root)
    reject_gzip_restore_residue!(static_root)

    tracked_logical_gzip_paths =
      Keyword.get(opts, :tracked_logical_gzip_paths, @tracked_logical_gzip_paths)

    runner = Keyword.get(opts, :command_runner, @system_command)

    command_opts = [
      cd: web_path,
      env: [{"MIX_ENV", to_string(Mix.env())}],
      into: IO.stream(:stdio, :line)
    ]

    logical_gzip_snapshots =
      snapshot_logical_gzip_variants!(static_root, tracked_logical_gzip_paths)

    Mix.shell().info("==> cleaning and rebuilding web assets")

    try do
      rebuild_web_assets!(runner, static_root, command_opts)
    rescue
      error ->
        restore_or_reraise!(static_root, logical_gzip_snapshots, error, __STACKTRACE__)
    end

    restore_logical_gzip_variants!(static_root, logical_gzip_snapshots)
    verify_web_digest_tree!(static_root)

    release
  end

  @doc false
  def assert_web_digest_tree_clean!(static_root) do
    leftovers =
      static_root
      |> static_files()
      |> Enum.filter(&generated_web_output?/1)

    if leftovers != [] do
      Mix.raise(
        "phx.digest.clean --all left generated asset output: #{Enum.join(leftovers, ", ")}"
      )
    end

    :ok
  end

  defp remove_generated_web_output!(static_root) do
    static_root
    |> static_files()
    |> Enum.filter(&generated_web_output?/1)
    |> Enum.each(fn relative ->
      static_root
      |> safe_static_file!(relative)
      |> File.rm!()
    end)
  end

  defp generated_web_output?(relative) do
    relative == @manifest_name or digested_asset?(relative) or
      String.ends_with?(relative, ".gz")
  end

  defp rebuild_web_assets!(runner, static_root, command_opts) do
    # An umbrella Mix invocation resolves the task from the umbrella root even
    # when the subprocess cwd is the web child. Bind the output explicitly so
    # cleanup and the cleanliness assertion always inspect the same tree.
    run_command!(
      runner,
      "mix",
      ["phx.digest.clean", "--all", "--output", static_root],
      command_opts
    )

    # Logical gzip siblings participate in the bounded clean rebuild, but the
    # explicit repository-owned subset is restored after source equality has
    # been checked. Ignored asset-build gzip output is deliberately not input.
    remove_generated_web_output!(static_root)
    assert_web_digest_tree_clean!(static_root)
    run_command!(runner, "mix", ["assets.npm"], command_opts)
    run_command!(runner, "mix", ["assets.deploy"], command_opts)
  end

  defp snapshot_logical_gzip_variants!(static_root, tracked_paths) do
    validate_tracked_logical_gzip_paths!(tracked_paths)

    existing_paths =
      static_root
      |> static_files()
      |> Enum.filter(&(String.ends_with?(&1, ".gz") and not digested_asset?(&1)))

    missing_paths = tracked_paths -- existing_paths

    if missing_paths != [] do
      Mix.raise("tracked logical gzip allowlist is missing: #{Enum.join(missing_paths, ", ")}")
    end

    unclassified_paths =
      existing_paths
      |> Kernel.--(tracked_paths)
      |> Enum.reject(&generated_logical_gzip?/1)

    if unclassified_paths != [] do
      Mix.raise(
        "logical gzip is neither repository-owned nor generated: " <>
          Enum.join(unclassified_paths, ", ")
      )
    end

    Enum.map(tracked_paths, &snapshot_logical_gzip!(static_root, &1))
  end

  defp snapshot_logical_gzip!(static_root, relative) do
    source_path = safe_static_file!(static_root, gzip_source_relative(relative))
    gzip_path = safe_static_file!(static_root, relative)
    source = File.read!(source_path)
    gzip = File.read!(gzip_path)

    unless gunzip_matches?(gzip, source) do
      Mix.raise("tracked logical gzip does not match its source: #{relative}")
    end

    %{
      relative: relative,
      source: source,
      gzip: gzip,
      mode: Bitwise.band(File.lstat!(gzip_path).mode, 0o777)
    }
  end

  defp validate_tracked_logical_gzip_paths!(paths) when is_list(paths) do
    canonical? = Enum.all?(paths, &canonical_tracked_logical_gzip_path?/1)

    unless canonical? and paths == Enum.sort(Enum.uniq(paths)) do
      Mix.raise("tracked logical gzip allowlist must be sorted, unique canonical paths")
    end
  end

  defp validate_tracked_logical_gzip_paths!(_paths) do
    Mix.raise("tracked logical gzip allowlist must be a list")
  end

  defp canonical_tracked_logical_gzip_path?(path) when is_binary(path) do
    String.ends_with?(path, ".gz") and not String.ends_with?(path, ".gz.gz") and
      Path.type(path) == :relative and path not in ["", "."] and
      not String.starts_with?(path, "../") and
      Path.relative_to(Path.expand(path, "/"), "/") == path and not digested_asset?(path)
  end

  defp canonical_tracked_logical_gzip_path?(_path), do: false

  defp restore_logical_gzip_variants!(static_root, snapshots) do
    Enum.each(snapshots, fn %{relative: relative, source: source, gzip: gzip, mode: mode} ->
      source_path = safe_static_file!(static_root, gzip_source_relative(relative))

      unless File.read!(source_path) == source do
        Mix.raise("logical asset changed while preserving its tracked gzip: #{relative}")
      end

      gzip_path = safe_static_output_file!(static_root, relative)
      atomic_replace_file!(static_root, relative, gzip_path, gzip, mode)
    end)
  end

  defp restore_or_reraise!(static_root, snapshots, original_error, original_stacktrace) do
    restoration =
      try do
        restore_logical_gzip_variants!(static_root, snapshots)
        :ok
      rescue
        restore_error -> {:error, restore_error}
      end

    case restoration do
      :ok ->
        reraise(original_error, original_stacktrace)

      {:error, restore_error} ->
        Mix.raise(
          "web asset build failed: #{Exception.message(original_error)}; " <>
            "tracked gzip restoration also failed: #{Exception.message(restore_error)}"
        )
    end
  end

  defp atomic_replace_file!(static_root, relative, target, contents, mode) do
    suffix = System.unique_integer([:positive, :monotonic])
    temporary_relative = "#{relative}.allbert-restore-#{suffix}"
    temporary = safe_static_output_file!(static_root, temporary_relative)
    ensure_restore_temporary_missing!(temporary)

    try do
      File.write!(temporary, contents, [:binary, :exclusive])
      File.chmod!(temporary, mode)
      File.rename!(temporary, target)
      verify_atomic_restore!(relative, target, contents, mode)
    after
      cleanup_restore_temporary!(temporary)
    end
  end

  defp ensure_restore_temporary_missing!(temporary) do
    case File.lstat(temporary) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> Mix.raise("tracked gzip restore temporary path already exists")
      {:error, reason} -> Mix.raise("tracked gzip restore temporary path failed: #{reason}")
    end
  end

  defp verify_atomic_restore!(relative, target, contents, mode) do
    restored? =
      File.read!(target) == contents and Bitwise.band(File.stat!(target).mode, 0o777) == mode

    unless restored?,
      do: Mix.raise("tracked gzip atomic restoration verification failed: #{relative}")
  end

  defp cleanup_restore_temporary!(temporary) do
    case File.lstat(temporary) do
      {:ok, %File.Stat{type: :regular}} -> File.rm!(temporary)
      {:error, :enoent} -> :ok
      _other -> :ok
    end
  end

  defp gzip_source_relative(relative), do: String.replace_suffix(relative, ".gz", "")

  defp generated_logical_gzip?(relative) do
    Enum.any?(@generated_logical_gzip_prefixes, &String.starts_with?(relative, &1))
  end

  defp reject_gzip_restore_residue!(static_root) do
    residues =
      static_root |> static_files() |> Enum.filter(&Regex.match?(@gzip_restore_residue, &1))

    if residues != [] do
      Mix.raise("atomic gzip restore residue requires removal: #{Enum.join(residues, ", ")}")
    end
  end

  defp gunzip_matches?(gzip, source) do
    :zlib.gunzip(gzip) == source
  rescue
    ErlangError -> false
  end

  defp validate_web_asset_boundary!(web_path, static_root) do
    {^web_path, :directory} = assert_boundary_path!(web_path, web_path, :directory)
    {^static_root, :directory} = assert_boundary_path!(web_path, static_root, :directory)
    :ok
  end

  @doc false
  def verify_web_digest_tree!(static_root) do
    manifest = read_asset_manifest!(static_root)
    {latest, digests, recorded} = validate_asset_manifest!(manifest)

    Enum.each(latest, fn {logical_path, digested_path} ->
      verify_asset_record!(static_root, logical_path, digested_path, digests[digested_path])
    end)

    verify_asset_file_set!(static_root, latest, recorded)
    %{logical_count: map_size(latest), digest_count: map_size(digests)}
  end

  defp read_asset_manifest!(static_root) do
    {manifest_path, :regular} =
      assert_boundary_path!(static_root, Path.join(static_root, @manifest_name), :regular)

    contents =
      case File.read(manifest_path) do
        {:ok, value} -> value
        {:error, reason} -> Mix.raise("Phoenix asset manifest is unavailable: #{reason}")
      end

    # `mix.exs` loads this helper before dependencies are guaranteed to exist.
    # Keep JSON execution runtime-bound so a fresh checkout can parse the project
    # without an undefined-module compiler warning; the release task itself has
    # already loaded project dependencies before this path executes.
    case apply(Jason, :decode, [contents]) do
      {:ok, manifest} -> manifest
      {:error, _reason} -> Mix.raise("Phoenix asset manifest is not valid JSON")
    end
  end

  defp validate_asset_manifest!(manifest) do
    latest = require_string_map!(manifest["latest"], "latest")
    digests = require_string_map!(manifest["digests"], "digests")

    if manifest["version"] != 1 or map_size(latest) == 0,
      do: Mix.raise("Phoenix asset manifest has an unsupported or empty shape")

    current = latest |> Map.values() |> Enum.sort()
    recorded = digests |> Map.keys() |> Enum.sort()

    if current != recorded,
      do: Mix.raise("Phoenix asset manifest retains orphan/stale digest records")

    {latest, digests, recorded}
  end

  defp verify_asset_file_set!(static_root, latest, recorded) do
    files = static_files(static_root)

    on_disk_digests =
      files
      |> Enum.map(&String.trim_trailing(&1, ".gz"))
      |> Enum.filter(&digested_asset?/1)
      |> Enum.uniq()
      |> Enum.sort()

    if on_disk_digests != recorded,
      do: Mix.raise("Phoenix static tree contains orphan/stale digest files")

    allowed_compressed = MapSet.new(Map.keys(latest) ++ recorded)

    orphan_compressed =
      files
      |> Enum.filter(&String.ends_with?(&1, ".gz"))
      |> Enum.map(&String.trim_trailing(&1, ".gz"))
      |> Enum.reject(&MapSet.member?(allowed_compressed, &1))

    if orphan_compressed != [] do
      Mix.raise(
        "Phoenix static tree contains orphan compressed files: #{Enum.join(orphan_compressed, ", ")}"
      )
    end
  end

  @doc false
  def patch_macos_openssl(release, opts \\ []) do
    if :os.type() == {:unix, :darwin} do
      exqlite = patch_macos_exqlite_install_name_tree!(release.path, opts)
      summary = patch_macos_openssl_tree!(release.path, opts)

      disposition =
        if summary.required?,
          do: "bundled #{length(summary.libraries)} measured OpenSSL library/libraries",
          else: "no measured OpenSSL edge; no library bundled"

      Mix.shell().info("==> macOS OpenSSL closure: " <> disposition)

      Mix.shell().info(
        "==> macOS Exqlite install name: #{exqlite.install_name}" <>
          if(exqlite.rewritten?, do: " (rewritten)", else: " (already stable)")
      )
    end

    release
  end

  @doc false
  def patch_linux_sctp(release, opts \\ []) do
    os_type = Keyword.get(opts, :os_type, :os.type())

    if os_type == {:unix, :linux} do
      summary = patch_linux_sctp_tree!(release.path, opts)

      Mix.shell().info(
        "==> Linux SCTP closure: bundled #{summary.library} from Debian libsctp1 #{summary.package_version}"
      )
    end

    release
  end

  @doc false
  def patch_linux_sctp_tree!(release_root, opts \\ []) do
    runner = Keyword.get(opts, :command_runner, @system_command)
    {source, package_version} = linux_sctp_inputs!(opts)

    assert_linux_sctp_soname!(source, runner)
    {release_root, :directory} = assert_boundary_path!(release_root, release_root, :directory)
    native_lib = ensure_release_directories!(release_root, ["native", "lib"])
    destination = Path.join(native_lib, @linux_sctp_file)
    soname_link = Path.join(native_lib, @linux_sctp_soname)

    {_destination, destination_type} =
      assert_boundary_path!(release_root, destination, :regular_or_missing)

    materialize_linux_sctp!(source, destination, destination_type)

    File.chmod!(destination, 0o755)
    assert_linux_sctp_soname!(destination, runner)
    ensure_soname_link!(release_root, soname_link)

    %{
      library: Path.relative_to(destination, release_root),
      soname_link: Path.relative_to(soname_link, release_root),
      package_version: package_version
    }
  end

  @doc false
  def patch_macos_exqlite_install_name_tree!(release_root, opts \\ []) do
    runner = Keyword.get(opts, :command_runner, @system_command)
    nif = exqlite_nif!(release_root)
    current = mach_o_install_id!(release_root, nif, runner)

    rewritten? =
      cond do
        current == @exqlite_install_name ->
          false

        Path.type(current) == :absolute and Path.basename(current) == @exqlite_nif ->
          run_command!(
            runner,
            "install_name_tool",
            ["-id", @exqlite_install_name, nif],
            stderr_to_stdout: true
          )

          run_command!(runner, "codesign", ["-f", "-s", "-", nif], stderr_to_stdout: true)
          true

        true ->
          Mix.raise("unsupported Exqlite install name #{current}")
      end

    unless mach_o_install_id!(release_root, nif, runner) == @exqlite_install_name do
      Mix.raise("Exqlite install name is not package-manager stable after patch")
    end

    run_command!(runner, "codesign", ["--verify", "--strict", nif], stderr_to_stdout: true)
    %{install_name: @exqlite_install_name, rewritten?: rewritten?}
  end

  @doc false
  def patch_macos_openssl_tree!(release_root, opts \\ []) do
    runner = Keyword.get(opts, :command_runner, @system_command)
    roots = crypto_nifs!(release_root)
    validate_staged_openssl_names!(release_root, roots)

    state = trace_openssl_closure!(release_root, roots, runner)
    remove_unreferenced_openssl!(release_root, roots, state.referenced)

    Enum.each(state.referenced, fn library ->
      stabilize_openssl_install_id!(release_root, library, runner)
    end)

    signing_order =
      state.referenced
      |> MapSet.to_list()
      |> Enum.sort()
      |> Kernel.++(
        state.edge_binaries
        |> MapSet.difference(state.referenced)
        |> MapSet.to_list()
        |> Enum.sort()
      )

    Enum.each(signing_order, fn path ->
      assert_boundary_path!(release_root, path, :regular)
      run_command!(runner, "codesign", ["-f", "-s", "-", path], stderr_to_stdout: true)
    end)

    verified = verify_portable_openssl_closure!(release_root, roots, runner)

    %{
      required?: MapSet.size(verified.libraries) > 0,
      libraries: relative_paths(verified.libraries, release_root),
      consumers: relative_paths(verified.edge_binaries, release_root)
    }
  end

  @doc false
  def finalize_license_evidence(release, opts \\ []) do
    licenses = Keyword.get(opts, :licenses_module, AllbertAssist.Licenses)
    repo_root = Keyword.get(opts, :repo_root, File.cwd!())
    actual_apps = release_applications(release.applications)

    with {:ok, catalog} <- licenses.load_catalog(repo_root: repo_root),
         {:ok, target} <- licenses.build_target(),
         {:ok, finalized} <-
           licenses.finalize(catalog, actual_apps, target,
             repo_root: repo_root,
             release_root: release.path
           ),
         {:ok, _verified} <-
           licenses.verify(
             release_root: release.path,
             manifest_sha256: finalized.manifest_sha256
           ) do
      Mix.shell().info(
        "==> finalized and verified license evidence " <> finalized.manifest_sha256
      )

      release
    else
      {:error, %{message: message}} -> Mix.raise("license finalization failed: " <> message)
      {:error, reason} -> Mix.raise("license finalization failed: #{inspect(reason)}")
    end
  end

  defp require_string_map!(value, name) when is_map(value) do
    if Enum.all?(value, fn {key, _value} -> is_binary(key) end),
      do: value,
      else: Mix.raise("Phoenix asset manifest #{name} keys must be strings")
  end

  defp require_string_map!(_value, name),
    do: Mix.raise("Phoenix asset manifest #{name} must be an object")

  defp verify_asset_record!(static_root, logical_path, digested_path, record)
       when is_binary(logical_path) and is_binary(digested_path) and is_map(record) do
    logical_file = safe_static_file!(static_root, logical_path)
    digested_file = safe_static_file!(static_root, digested_path)
    logical_contents = File.read!(logical_file)
    digested_contents = File.read!(digested_file)
    digest = logical_contents |> :erlang.md5() |> Base.encode16(case: :lower)
    sha512 = digested_contents |> then(&:crypto.hash(:sha512, &1)) |> Base.encode64()

    unless record["logical_path"] == logical_path and record["digest"] == digest and
             record["sha512"] == sha512 and record["size"] == byte_size(logical_contents) and
             digest_from_path(digested_path) == digest do
      Mix.raise("Phoenix asset digest record is corrupt for #{logical_path}")
    end
  end

  defp verify_asset_record!(_static_root, logical_path, _digested_path, _record),
    do: Mix.raise("Phoenix asset digest record is invalid for #{inspect(logical_path)}")

  defp digest_from_path(path) do
    case Regex.run(~r/-([0-9a-f]{32})\.[^\/]+$/, path, capture: :all_but_first) do
      [digest] -> digest
      _other -> nil
    end
  end

  defp digested_asset?(path), do: Regex.match?(@digest_file, path)

  defp static_files(root) do
    {root, :directory} = assert_boundary_path!(root, root, :directory)
    collect_boundary_files!(root, root) |> Enum.sort()
  end

  defp collect_boundary_files!(root, directory) do
    directory
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      path = Path.join(directory, name)

      case assert_boundary_path!(root, path, :existing) do
        {_path, :regular} -> [Path.relative_to(path, root)]
        {_path, :directory} -> collect_boundary_files!(root, path)
      end
    end)
  end

  defp safe_static_file!(root, relative) do
    normalized = relative |> Path.expand(root) |> Path.relative_to(root)

    unless relative == normalized and Path.type(relative) == :relative and
             relative not in ["", "."] and
             not String.starts_with?(relative, "../") do
      Mix.raise("Phoenix asset manifest contains an unsafe path")
    end

    path = Path.expand(relative, root)

    unless path_within?(path, root), do: Mix.raise("Phoenix asset path escapes the static root")
    {path, :regular} = assert_boundary_path!(root, path, :regular)
    path
  end

  defp safe_static_output_file!(root, relative) do
    normalized = relative |> Path.expand(root) |> Path.relative_to(root)

    unless relative == normalized and Path.type(relative) == :relative and
             relative not in ["", "."] and
             not String.starts_with?(relative, "../") do
      Mix.raise("Phoenix asset output contains an unsafe path")
    end

    path = Path.expand(relative, root)

    unless path_within?(path, root), do: Mix.raise("Phoenix asset output escapes the static root")
    {path, _type} = assert_boundary_path!(root, path, :regular_or_missing)
    path
  end

  defp crypto_nifs!(release_root) do
    {release_root, :directory} = assert_boundary_path!(release_root, release_root, :directory)
    lib_root = Path.join(release_root, "lib")
    assert_boundary_path!(release_root, lib_root, :directory)

    crypto_roots =
      lib_root
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, "crypto-"))
      |> Enum.map(&Path.join(lib_root, &1))

    crypto_root =
      case crypto_roots do
        [path] ->
          assert_boundary_path!(release_root, path, :directory)
          path

        [] ->
          Mix.raise("assembled release contains no crypto application")

        _many ->
          Mix.raise("assembled release contains multiple crypto applications")
      end

    nif_root = Path.join([crypto_root, "priv", "lib"])
    assert_boundary_path!(release_root, Path.dirname(nif_root), :directory)
    assert_boundary_path!(release_root, nif_root, :directory)

    roots =
      nif_root
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".so"))
      |> Enum.map(fn name ->
        path = Path.join(nif_root, name)
        assert_boundary_path!(release_root, path, :regular)
        path
      end)
      |> Enum.sort()

    if roots == [], do: Mix.raise("assembled release contains no crypto NIFs")
    roots
  end

  defp exqlite_nif!(release_root) do
    {release_root, :directory} = assert_boundary_path!(release_root, release_root, :directory)
    lib_root = Path.join(release_root, "lib")
    assert_boundary_path!(release_root, lib_root, :directory)

    candidates =
      lib_root
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, "exqlite-"))
      |> Enum.map(&Path.join([lib_root, &1, "priv", @exqlite_nif]))
      |> Enum.filter(&File.exists?/1)
      |> Enum.map(fn path ->
        assert_boundary_path!(release_root, path, :regular)
        path
      end)

    case candidates do
      [nif] -> nif
      _other -> Mix.raise("assembled release must contain exactly one Exqlite NIF")
    end
  end

  defp mach_o_install_id!(release_root, binary, runner) do
    assert_boundary_path!(release_root, binary, :regular)

    case runner
         |> run_command!("otool", ["-D", binary], stderr_to_stdout: true)
         |> String.split("\n", trim: true)
         |> Enum.map(&String.trim/1)
         |> Enum.drop(1) do
      [value] -> value
      _other -> Mix.raise("could not resolve the Mach-O install id for #{binary}")
    end
  end

  defp validate_staged_openssl_names!(release_root, roots) do
    roots
    |> Enum.map(&Path.dirname/1)
    |> Enum.uniq()
    |> Enum.each(fn directory ->
      directory
      |> File.ls!()
      |> Enum.filter(&Regex.match?(@openssl_dylib, &1))
      |> Enum.each(fn name ->
        assert_boundary_path!(release_root, Path.join(directory, name), :regular)
        require_catalogued_openssl_name!(name)
      end)
    end)
  end

  defp trace_openssl_closure!(release_root, roots, runner) do
    initial = %{
      seen: MapSet.new(),
      referenced: MapSet.new(),
      edge_binaries: MapSet.new()
    }

    walk_openssl_closure(release_root, roots, initial, runner)
  end

  defp walk_openssl_closure(_release_root, [], state, _runner), do: state

  defp walk_openssl_closure(release_root, [binary | rest], state, runner) do
    if MapSet.member?(state.seen, binary) do
      walk_openssl_closure(release_root, rest, state, runner)
    else
      openssl_links = openssl_links!(release_root, binary, runner)
      state = %{state | seen: MapSet.put(state.seen, binary)}

      {state, discovered} =
        Enum.reduce(openssl_links, {state, []}, fn link, accumulator ->
          trace_openssl_link!(release_root, binary, link, accumulator, runner)
        end)

      walk_openssl_closure(release_root, rest ++ Enum.reverse(discovered), state, runner)
    end
  end

  defp trace_openssl_link!(release_root, binary, link, {state, queue}, runner) do
    {dependency, rewrite?} = materialize_openssl_dependency!(release_root, binary, link)

    if rewrite? do
      assert_boundary_path!(release_root, binary, :regular)

      run_command!(
        runner,
        "install_name_tool",
        ["-change", link, "@loader_path/" <> Path.basename(dependency), binary],
        stderr_to_stdout: true
      )
    end

    state = %{
      state
      | referenced: MapSet.put(state.referenced, dependency),
        edge_binaries: MapSet.put(state.edge_binaries, binary)
    }

    {state, [dependency | queue]}
  end

  defp materialize_openssl_dependency!(release_root, consumer, link) do
    name = Path.basename(link)
    require_catalogued_openssl_name!(name)

    destination = Path.join(Path.dirname(consumer), name)

    cond do
      String.starts_with?(link, "@loader_path/") ->
        unless link == @catalogued_openssl_loader do
          Mix.raise(
            "unsupported OpenSSL loader path #{link}; " <>
              "v1.2.5 permits only #{@catalogued_openssl_loader}"
          )
        end

        source = resolve_loader_path!(release_root, consumer, link)
        {source, false}

      String.starts_with?(link, "@rpath/") ->
        Mix.raise("OpenSSL @rpath dependency is unsupported in v1.2.5: #{link}")

      Path.type(link) == :absolute ->
        unless match?({:ok, %File.Stat{type: :regular}}, File.stat(link)),
          do: Mix.raise("measured OpenSSL dependency is missing: #{link}")

        copy_measured_dependency!(release_root, link, destination)
        {destination, true}

      true ->
        Mix.raise("unresolved OpenSSL dependency path: #{link}")
    end
  end

  defp resolve_loader_path!(release_root, consumer, "@loader_path/" <> relative) do
    directory = Path.dirname(consumer)
    resolved = Path.expand(relative, directory)

    unless path_within?(resolved, directory),
      do: Mix.raise("OpenSSL loader path escapes its release directory")

    assert_boundary_path!(release_root, resolved, :regular)
    resolved
  end

  defp copy_measured_dependency!(release_root, source, destination) do
    {destination, destination_type} =
      assert_boundary_path!(release_root, destination, :regular_or_missing)

    cond do
      Path.expand(source) == Path.expand(destination) ->
        :ok

      destination_type == :missing ->
        File.cp!(source, destination)
        File.chmod!(destination, 0o755)

      File.read!(source) == File.read!(destination) ->
        File.chmod!(destination, 0o755)

      true ->
        Mix.raise("OpenSSL destination collision: #{destination} differs from measured source")
    end
  end

  defp assert_linux_sctp_soname!(path, runner) do
    output = run_command!(runner, "readelf", ["-d", path], stderr_to_stdout: true)

    sonames =
      Regex.scan(~r/\(SONAME\).*?\[([^\]]+)\]/, output, capture: :all_but_first)
      |> List.flatten()

    unless sonames == [@linux_sctp_soname],
      do: Mix.raise("Linux SCTP SONAME must be #{@linux_sctp_soname}; found #{inspect(sonames)}")
  end

  defp linux_sctp_inputs!(opts) do
    source = Keyword.get(opts, :source_path) || System.get_env("ALLBERT_RELEASE_LIBSCTP_PATH")

    package_version =
      Keyword.get(opts, :package_version) ||
        System.get_env("ALLBERT_RELEASE_LIBSCTP_PACKAGE_VERSION")

    unless package_version == @linux_sctp_package_version do
      Mix.raise(
        "Linux release requires Debian libsctp1 #{@linux_sctp_package_version}; " <>
          "found #{package_version || "no package version"}"
      )
    end

    valid_source? =
      is_binary(source) and Path.type(source) == :absolute and
        Path.basename(source) == @linux_sctp_file and
        match?({:ok, %File.Stat{type: :regular}}, File.lstat(source))

    unless valid_source?,
      do: Mix.raise("Linux SCTP source must be a regular file named #{@linux_sctp_file}")

    {source, package_version}
  end

  defp materialize_linux_sctp!(source, destination, :missing),
    do: File.cp!(source, destination)

  defp materialize_linux_sctp!(source, destination, :regular) do
    unless File.read!(source) == File.read!(destination),
      do: Mix.raise("SCTP destination collision: #{destination} differs from measured source")
  end

  defp ensure_release_directories!(release_root, parts) do
    Enum.reduce(parts, release_root, fn part, parent ->
      path = Path.join(parent, part)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} ->
          path

        {:error, :enoent} ->
          File.mkdir!(path)
          File.chmod!(path, 0o755)
          path

        {:ok, %File.Stat{type: type}} ->
          Mix.raise("unsafe Linux native closure path is #{type}, expected directory: #{path}")

        {:error, reason} ->
          Mix.raise("Linux native closure path is unavailable (#{reason}): #{path}")
      end
    end)
  end

  defp ensure_soname_link!(release_root, path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        File.ln_s!(@linux_sctp_file, path)

      {:ok, %File.Stat{type: :symlink}} ->
        unless File.read_link!(path) == @linux_sctp_file,
          do: Mix.raise("Linux SCTP SONAME link has an unexpected target")

      {:ok, %File.Stat{type: type}} ->
        Mix.raise("Linux SCTP SONAME path is #{type}, expected symlink")

      {:error, reason} ->
        Mix.raise("Linux SCTP SONAME path is unavailable (#{reason})")
    end

    unless path_within?(path, release_root),
      do: Mix.raise("Linux SCTP SONAME link escapes the release root")

    path
  end

  defp remove_unreferenced_openssl!(release_root, roots, referenced) do
    roots
    |> Enum.map(&Path.dirname/1)
    |> Enum.uniq()
    |> Enum.each(fn directory ->
      directory
      |> File.ls!()
      |> Enum.filter(&Regex.match?(@openssl_dylib, &1))
      |> Enum.map(&Path.join(directory, &1))
      |> Enum.reject(&MapSet.member?(referenced, &1))
      |> Enum.each(fn path ->
        assert_boundary_path!(release_root, path, :regular)
        File.rm!(path)
      end)
    end)
  end

  defp verify_portable_openssl_closure!(release_root, roots, runner) do
    state =
      verify_openssl_queue(
        release_root,
        roots,
        %{seen: MapSet.new(), libraries: MapSet.new(), edge_binaries: MapSet.new()},
        runner
      )

    relevant = MapSet.union(state.libraries, state.edge_binaries)

    Enum.each(Enum.sort(MapSet.to_list(relevant)), fn path ->
      assert_boundary_path!(release_root, path, :regular)
      run_command!(runner, "codesign", ["--verify", "--strict", path], stderr_to_stdout: true)
    end)

    state
  end

  defp verify_openssl_queue(_release_root, [], state, _runner), do: state

  defp verify_openssl_queue(release_root, [binary | rest], state, runner) do
    if MapSet.member?(state.seen, binary) do
      verify_openssl_queue(release_root, rest, state, runner)
    else
      links = openssl_links!(release_root, binary, runner)
      seen = MapSet.put(state.seen, binary)

      {libraries, discovered} =
        Enum.reduce(links, {state.libraries, []}, fn link, accumulator ->
          verify_openssl_link!(release_root, binary, link, accumulator)
        end)

      edge_binaries =
        if links == [],
          do: state.edge_binaries,
          else: MapSet.put(state.edge_binaries, binary)

      next = %{state | seen: seen, libraries: libraries, edge_binaries: edge_binaries}
      verify_openssl_queue(release_root, rest ++ Enum.reverse(discovered), next, runner)
    end
  end

  defp verify_openssl_link!(release_root, binary, link, {libraries, queue}) do
    unless String.starts_with?(link, "@loader_path/") do
      Mix.raise("OpenSSL dependency is not loader-relative after patch: #{link}")
    end

    dependency = resolve_loader_path!(release_root, binary, link)
    {MapSet.put(libraries, dependency), [dependency | queue]}
  end

  defp stabilize_openssl_install_id!(release_root, library, runner) do
    current = mach_o_install_id!(release_root, library, runner)

    cond do
      current == @catalogued_openssl_loader ->
        :ok

      Path.type(current) == :absolute and Path.basename(current) == @catalogued_openssl ->
        run_command!(
          runner,
          "install_name_tool",
          ["-id", @catalogued_openssl_loader, library],
          stderr_to_stdout: true
        )

      true ->
        Mix.raise("unsupported OpenSSL install id #{current}")
    end

    unless mach_o_install_id!(release_root, library, runner) == @catalogued_openssl_loader do
      Mix.raise("OpenSSL install id is not loader-relative after patch")
    end
  end

  defp openssl_links!(release_root, binary, runner) do
    links =
      release_root
      |> otool_dependencies!(binary, runner)
      |> Enum.filter(&openssl_link?/1)

    Enum.each(links, &require_catalogued_openssl_name!(Path.basename(&1)))
    links
  end

  defp otool_dependencies!(release_root, binary, runner) do
    assert_boundary_path!(release_root, binary, :regular)
    output = run_command!(runner, "otool", ["-L", binary], stderr_to_stdout: true)

    dependencies =
      output
      |> String.split("\n")
      |> Enum.drop(1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn line -> line |> String.split(~r/\s+\(/, parts: 2) |> hd() end)

    case Path.extname(binary) do
      ".dylib" -> List.delete(dependencies, otool_install_id!(release_root, binary, runner))
      _other -> dependencies
    end
  end

  defp otool_install_id!(release_root, binary, runner) do
    assert_boundary_path!(release_root, binary, :regular)

    install_id =
      case runner
           |> run_command!("otool", ["-D", binary], stderr_to_stdout: true)
           |> String.split("\n", trim: true)
           |> Enum.map(&String.trim/1)
           |> Enum.drop(1) do
        [value] -> value
        _other -> Mix.raise("could not resolve the Mach-O install id for #{binary}")
      end

    unless Path.basename(install_id) == @catalogued_openssl do
      Mix.raise(
        "unsupported OpenSSL install id #{Path.basename(install_id)}; " <>
          "v1.2.5 permits only #{@catalogued_openssl}"
      )
    end

    install_id
  end

  defp openssl_link?(link), do: Regex.match?(@openssl_dylib, Path.basename(link))

  defp require_catalogued_openssl_name!(@catalogued_openssl), do: :ok

  defp require_catalogued_openssl_name!(name) do
    Mix.raise(
      "unsupported OpenSSL dependency #{name}; v1.2.5 permits only #{@catalogued_openssl}"
    )
  end

  defp run_command!(runner, executable, args, opts) do
    case runner.(executable, args, opts) do
      {output, 0} ->
        output

      {output, status} ->
        detail =
          if is_binary(output), do: String.trim(output), else: "see streamed command output"

        Mix.raise("#{executable} failed (#{status}): #{detail}")
    end
  end

  defp release_applications(applications) when is_map(applications) do
    applications
    |> Enum.map(fn {application, properties} ->
      %{
        "application" => Atom.to_string(application),
        "version" => properties |> Keyword.fetch!(:vsn) |> to_string()
      }
    end)
    |> Enum.sort_by(& &1["application"])
  end

  defp relative_paths(paths, release_root) do
    paths
    |> MapSet.to_list()
    |> Enum.map(&Path.relative_to(&1, release_root))
    |> Enum.sort()
  end

  defp assert_boundary_path!(root, path, expected) do
    root = Path.expand(root)
    path = Path.expand(path)

    unless path_within?(path, root),
      do: Mix.raise("unsafe release/static path escapes its root: #{path}")

    root_type = boundary_lstat_type!(root, false)

    unless root_type == :directory,
      do: Mix.raise("unsafe release/static root is #{root_type}, expected directory: #{root}")

    relative = Path.relative_to(path, root)

    if relative == "." do
      validate_boundary_leaf!(path, root_type, expected)
    else
      walk_boundary_path!(root, Path.split(relative), expected)
    end
  end

  defp walk_boundary_path!(parent, [leaf], expected) do
    path = Path.join(parent, leaf)
    type = boundary_lstat_type!(path, expected == :regular_or_missing)
    validate_boundary_leaf!(path, type, expected)
  end

  defp walk_boundary_path!(parent, [part | rest], expected) do
    path = Path.join(parent, part)
    type = boundary_lstat_type!(path, false)

    unless type == :directory do
      Mix.raise("unsafe release/static path ancestor is #{type}, expected directory: #{path}")
    end

    walk_boundary_path!(path, rest, expected)
  end

  defp boundary_lstat_type!(path, allow_missing?) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: type}} ->
        type

      {:error, :enoent} when allow_missing? ->
        :missing

      {:error, reason} ->
        Mix.raise("unsafe release/static path is unavailable (#{reason}): #{path}")
    end
  end

  defp validate_boundary_leaf!(path, type, :existing) when type in [:directory, :regular],
    do: {path, type}

  defp validate_boundary_leaf!(path, :regular, :regular), do: {path, :regular}
  defp validate_boundary_leaf!(path, :directory, :directory), do: {path, :directory}

  defp validate_boundary_leaf!(path, type, :regular_or_missing)
       when type in [:regular, :missing],
       do: {path, type}

  defp validate_boundary_leaf!(path, type, expected) do
    Mix.raise("unsafe release/static path is #{type}, expected #{expected}: #{path}")
  end

  defp path_within?(path, root) do
    expanded_root = Path.expand(root)
    expanded_path = Path.expand(path)
    expanded_path == expanded_root or String.starts_with?(expanded_path, expanded_root <> "/")
  end
end
