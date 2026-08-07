# Serial lane workers run from the child app, where the umbrella release project
# and its helper are not loaded implicitly. Keep the test valid in both contexts.
unless Code.ensure_loaded?(AllbertAssist.Umbrella.MixProject) and
         function_exported?(AllbertAssist.Umbrella.MixProject, :project, 0) do
  Code.require_file(Path.expand("../../../../../mix.exs", __DIR__))
end

defmodule AllbertAssist.Release.FinalArtifactTest.FakeLicenses do
  @manifest_sha256 String.duplicate("a", 64)

  def load_catalog(opts) do
    send(self(), {:license_call, :load_catalog, opts})
    {:ok, %{"catalog" => true}}
  end

  def build_target do
    send(self(), {:license_call, :build_target})

    {:ok,
     %{
       "triple" => "macos-arm64",
       "otp_version" => "29.0.1",
       "elixir_version" => "1.19.5",
       "erts_version" => "17.0.1"
     }}
  end

  def finalize(catalog, applications, target, opts) do
    send(self(), {:license_call, :finalize, catalog, applications, target, opts})
    {:ok, %{manifest_sha256: @manifest_sha256}}
  end

  def verify(opts) do
    send(self(), {:license_call, :verify, opts})
    {:ok, %{verified: true}}
  end
end

defmodule AllbertAssist.Release.LicensesFinalArtifactTest do
  use ExUnit.Case, async: false

  @moduletag :external_runtime_serial

  alias AllbertAssist.Release.FinalArtifact
  alias AllbertAssist.Release.FinalArtifactTest.FakeLicenses
  alias AllbertAssist.SecurityFixtures.AssertBinding
  alias AllbertAssist.Umbrella.MixProject

  @manifest_sha256 String.duplicate("a", 64)

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-final-artifact-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "release composition helper loads warning-free before project dependencies" do
    helper = Path.expand("../../../../../scripts/release/final_artifact.exs", __DIR__)
    elixir = System.find_executable("elixir")
    assert is_binary(elixir)

    {output, status} =
      System.cmd(
        elixir,
        ["-e", "Code.require_file(System.fetch_env!(\"FINAL_ARTIFACT_HELPER\"))"],
        env: [{"FINAL_ARTIFACT_HELPER", helper}],
        stderr_to_stdout: true
      )

    assert status == 0
    refute output =~ "warning:"
  end

  test "release composition orders every payload mutation before the license finalizer" do
    steps =
      MixProject.project()
      |> Keyword.fetch!(:releases)
      |> Keyword.fetch!(:allbert)
      |> Keyword.fetch!(:steps)
      |> Enum.map(fn
        step when is_atom(step) -> step
        step when is_function(step, 1) -> step |> Function.info(:name) |> elem(1)
      end)

    assert steps == [
             :build_web_assets,
             :assemble,
             :stage_plugins,
             :patch_macos_openssl,
             :patch_linux_sctp,
             :install_dispatcher,
             :finalize_license_evidence
           ]

    AssertBinding.check!("v121-license-final-artifact-001", [
      :payload_mutations_ordered,
      :license_finalizer_last,
      :final_tree_verified
    ])
  end

  test "asset build preserves only allowlisted repository gzip bytes", %{root: root} do
    web_path = Path.join(root, "web")
    static_root = Path.join(web_path, "priv/static")
    File.mkdir_p!(Path.join(static_root, "tracked"))
    File.mkdir_p!(Path.join(static_root, "assets/generated"))
    File.write!(Path.join(static_root, "cache_manifest.json"), "old manifest")
    File.write!(Path.join(static_root, "assets/old-00000000000000000000000000000000.js"), "old")
    File.write!(Path.join(static_root, "assets/old.js.gz"), "old")
    File.write!(Path.join(static_root, "tracked/app.js"), "current asset")
    File.write!(Path.join(static_root, "assets/generated/app.js"), "generated asset")

    preserved_gzip =
      "current asset"
      |> :zlib.gzip()
      |> then(fn <<prefix::binary-size(9), _os, rest::binary>> ->
        <<prefix::binary, 255, rest::binary>>
      end)

    generated_gzip = :zlib.gzip("generated asset")

    File.write!(Path.join(static_root, "tracked/app.js.gz"), preserved_gzip)
    File.chmod!(Path.join(static_root, "tracked/app.js.gz"), 0o600)
    File.write!(Path.join(static_root, "assets/generated/app.js.gz"), generated_gzip)

    runner = fn
      "mix", ["phx.digest.clean", "--all", "--output", ^static_root], opts ->
        send(self(), {:asset_command, :clean, opts})
        File.rm!(Path.join(static_root, "cache_manifest.json"))
        File.rm!(Path.join(static_root, "assets/old-00000000000000000000000000000000.js"))
        File.rm!(Path.join(static_root, "tracked/app.js.gz"))
        {"", 0}

      "mix", ["assets.npm"], opts ->
        send(self(), {:asset_command, :npm, opts})
        refute File.exists?(Path.join(static_root, "assets/old.js.gz"))
        refute File.exists?(Path.join(static_root, "tracked/app.js.gz"))
        refute File.exists?(Path.join(static_root, "assets/generated/app.js.gz"))
        {"", 0}

      "mix", ["assets.deploy"], opts ->
        send(self(), {:asset_command, :deploy, opts})
        write_asset_manifest!(static_root, "tracked/app.js", "current asset")
        {"", 0}
    end

    release = %Mix.Release{path: Path.join(root, "release")}

    assert ^release =
             FinalArtifact.build_web_assets(release,
               web_path: web_path,
               tracked_logical_gzip_paths: ["tracked/app.js.gz"],
               command_runner: runner
             )

    assert_receive {:asset_command, :clean, _opts}
    assert_receive {:asset_command, :npm, _opts}
    assert_receive {:asset_command, :deploy, _opts}
    refute_receive {:asset_command, _unexpected, _opts}

    assert %{logical_count: 1, digest_count: 1} =
             FinalArtifact.verify_web_digest_tree!(static_root)

    tracked_gzip = Path.join(static_root, "tracked/app.js.gz")
    assert File.read!(tracked_gzip) == preserved_gzip
    assert Bitwise.band(File.stat!(tracked_gzip).mode, 0o777) == 0o600
    refute File.exists?(Path.join(static_root, "assets/generated/app.js.gz"))
  end

  test "asset build rejects a symlinked Web root before invoking commands", %{root: root} do
    external_web = Path.join(root, "external-web")
    external_static = Path.join(external_web, "priv/static")
    web_path = Path.join(root, "web-link")
    sentinel = Path.join(external_static, "keep.txt")

    File.mkdir_p!(external_static)
    File.write!(sentinel, "keep")
    File.ln_s!(external_web, web_path)

    assert_raise Mix.Error, ~r/unsafe release\/static root is symlink/, fn ->
      FinalArtifact.build_web_assets(%Mix.Release{path: Path.join(root, "release")},
        web_path: web_path,
        tracked_logical_gzip_paths: [],
        command_runner: fn _executable, _args, _opts -> flunk("command must not run") end
      )
    end

    assert File.read!(sentinel) == "keep"
  end

  test "asset build rejects a symlinked static-root ancestor before invoking commands", %{
    root: root
  } do
    web_path = Path.join(root, "web")
    external_priv = Path.join(root, "external-priv")
    external_static = Path.join(external_priv, "static")
    sentinel = Path.join(external_static, "keep.txt")

    File.mkdir_p!(web_path)
    File.mkdir_p!(external_static)
    File.write!(sentinel, "keep")
    File.ln_s!(external_priv, Path.join(web_path, "priv"))

    assert_raise Mix.Error, ~r/path ancestor is symlink/, fn ->
      FinalArtifact.build_web_assets(%Mix.Release{path: Path.join(root, "release")},
        web_path: web_path,
        tracked_logical_gzip_paths: [],
        command_runner: fn _executable, _args, _opts -> flunk("command must not run") end
      )
    end

    assert File.read!(sentinel) == "keep"
  end

  test "asset command failure restores allowlisted gzip bytes and mode", %{root: root} do
    web_path = Path.join(root, "web")
    static_root = Path.join(web_path, "priv/static")
    gzip_path = Path.join(static_root, "tracked/app.js.gz")
    gzip = write_logical_gzip!(static_root, "tracked/app.js", "current asset", 0o600)

    runner = fn
      "mix", ["phx.digest.clean", "--all", "--output", ^static_root], _opts ->
        File.rm!(gzip_path)
        {"clean exploded", 9}
    end

    assert_raise Mix.Error, ~r/mix failed \(9\): clean exploded/, fn ->
      FinalArtifact.build_web_assets(%Mix.Release{path: Path.join(root, "release")},
        web_path: web_path,
        tracked_logical_gzip_paths: ["tracked/app.js.gz"],
        command_runner: runner
      )
    end

    assert File.read!(gzip_path) == gzip
    assert Bitwise.band(File.stat!(gzip_path).mode, 0o777) == 0o600
  end

  test "restore failure retains the original asset-command diagnostic", %{root: root} do
    web_path = Path.join(root, "web")
    static_root = Path.join(web_path, "priv/static")
    source_path = Path.join(static_root, "tracked/app.js")
    gzip_path = source_path <> ".gz"
    write_logical_gzip!(static_root, "tracked/app.js", "current asset", 0o600)

    runner = fn
      "mix", ["phx.digest.clean", "--all", "--output", ^static_root], _opts ->
        File.rm!(gzip_path)
        File.rm!(source_path)
        {"clean exploded", 9}
    end

    assert_raise Mix.Error,
                 ~r/web asset build failed: mix failed \(9\): clean exploded; tracked gzip restoration also failed:/,
                 fn ->
                   FinalArtifact.build_web_assets(
                     %Mix.Release{path: Path.join(root, "release")},
                     web_path: web_path,
                     tracked_logical_gzip_paths: ["tracked/app.js.gz"],
                     command_runner: runner
                   )
                 end
  end

  test "asset build rejects source drift instead of restoring stale gzip", %{root: root} do
    web_path = Path.join(root, "web")
    static_root = Path.join(web_path, "priv/static")
    gzip_path = Path.join(static_root, "tracked/app.js.gz")
    write_logical_gzip!(static_root, "tracked/app.js", "current asset", 0o600)

    runner = fn
      "mix", ["phx.digest.clean", "--all", "--output", ^static_root], _opts ->
        {"", 0}

      "mix", ["assets.npm"], _opts ->
        {"", 0}

      "mix", ["assets.deploy"], _opts ->
        write_asset_manifest!(static_root, "tracked/app.js", "changed asset")
        {"", 0}
    end

    assert_raise Mix.Error, ~r/logical asset changed while preserving its tracked gzip/, fn ->
      FinalArtifact.build_web_assets(%Mix.Release{path: Path.join(root, "release")},
        web_path: web_path,
        tracked_logical_gzip_paths: ["tracked/app.js.gz"],
        command_runner: runner
      )
    end

    refute File.exists?(gzip_path)
  end

  test "asset build refuses a symlink collision at the tracked gzip target", %{root: root} do
    web_path = Path.join(root, "web")
    static_root = Path.join(web_path, "priv/static")
    gzip_path = Path.join(static_root, "tracked/app.js.gz")
    external = Path.join(root, "outside.gz")
    File.write!(external, "outside")
    write_logical_gzip!(static_root, "tracked/app.js", "current asset", 0o600)

    runner = fn
      "mix", ["phx.digest.clean", "--all", "--output", ^static_root], _opts ->
        {"", 0}

      "mix", ["assets.npm"], _opts ->
        {"", 0}

      "mix", ["assets.deploy"], _opts ->
        write_asset_manifest!(static_root, "tracked/app.js", "current asset")
        File.ln_s!(external, gzip_path)
        {"", 0}
    end

    assert_raise Mix.Error, ~r/unsafe release\/static path is symlink/, fn ->
      FinalArtifact.build_web_assets(%Mix.Release{path: Path.join(root, "release")},
        web_path: web_path,
        tracked_logical_gzip_paths: ["tracked/app.js.gz"],
        command_runner: runner
      )
    end

    assert File.read!(external) == "outside"
  end

  test "tracked gzip allowlist rejects a repeated gzip suffix", %{root: root} do
    web_path = Path.join(root, "web")
    static_root = Path.join(web_path, "priv/static")
    File.mkdir_p!(Path.join(static_root, "tracked"))
    File.write!(Path.join(static_root, "tracked/archive.gz"), "source")
    File.write!(Path.join(static_root, "tracked/archive.gz.gz"), :zlib.gzip("source"))

    assert_raise Mix.Error, ~r/allowlist must be sorted, unique canonical paths/, fn ->
      FinalArtifact.build_web_assets(%Mix.Release{path: Path.join(root, "release")},
        web_path: web_path,
        tracked_logical_gzip_paths: ["tracked/archive.gz.gz"],
        command_runner: fn _executable, _args, _opts -> flunk("command must not run") end
      )
    end
  end

  test "asset build rejects a crashed atomic-restore residue before commands", %{root: root} do
    web_path = Path.join(root, "web")
    static_root = Path.join(web_path, "priv/static")
    residue = Path.join(static_root, "workspace-sw.js.gz.allbert-restore-42")
    File.mkdir_p!(static_root)
    File.write!(residue, "partial gzip")

    assert_raise Mix.Error, ~r/atomic gzip restore residue/, fn ->
      FinalArtifact.build_web_assets(%Mix.Release{path: Path.join(root, "release")},
        web_path: web_path,
        tracked_logical_gzip_paths: [],
        command_runner: fn _executable, _args, _opts -> flunk("command must not run") end
      )
    end

    assert File.read!(residue) == "partial gzip"
  end

  test "asset checks reject leftovers after clean and orphan digest output", %{root: root} do
    static_root = Path.join(root, "priv/static")
    File.mkdir_p!(Path.join(static_root, "assets"))

    orphan = "assets/app-00000000000000000000000000000000.js"
    File.write!(Path.join(static_root, orphan), "orphan")

    assert_raise Mix.Error, ~r/left generated asset output/, fn ->
      FinalArtifact.assert_web_digest_tree_clean!(static_root)
    end

    File.rm!(Path.join(static_root, orphan))
    write_asset_manifest!(static_root, "assets/app.js", "current asset")
    File.write!(Path.join(static_root, "assets/old-11111111111111111111111111111111.js"), "old")

    assert_raise Mix.Error, ~r/orphan\/stale digest files/, fn ->
      FinalArtifact.verify_web_digest_tree!(static_root)
    end
  end

  test "asset verification rejects corrupt digested bytes and symlink paths", %{root: root} do
    corrupt_root = Path.join(root, "corrupt/priv/static")
    digested_path = write_asset_manifest!(corrupt_root, "assets/app.js", "current asset")
    File.write!(Path.join(corrupt_root, digested_path), "changed asset")

    assert_raise Mix.Error, ~r/digest record is corrupt/, fn ->
      FinalArtifact.verify_web_digest_tree!(corrupt_root)
    end

    leaf_root = Path.join(root, "leaf/priv/static")
    leaf_digest = write_asset_manifest!(leaf_root, "assets/app.js", "current asset")
    external = Path.join(root, "outside-digest.js")
    File.write!(external, "current asset")
    File.rm!(Path.join(leaf_root, leaf_digest))
    File.ln_s!(external, Path.join(leaf_root, leaf_digest))

    assert_raise Mix.Error, ~r/unsafe release\/static path is symlink/, fn ->
      FinalArtifact.verify_web_digest_tree!(leaf_root)
    end

    ancestor_root = Path.join(root, "ancestor/priv/static")
    write_asset_manifest!(ancestor_root, "assets/app.js", "current asset")
    real_assets = Path.join(root, "ancestor-assets")
    File.rename!(Path.join(ancestor_root, "assets"), real_assets)
    File.ln_s!(real_assets, Path.join(ancestor_root, "assets"))

    assert_raise Mix.Error, ~r/path ancestor is symlink/, fn ->
      FinalArtifact.verify_web_digest_tree!(ancestor_root)
    end
  end

  test "streamed asset command failures retain their stable command diagnostic", %{root: root} do
    web_path = Path.join(root, "web")
    static_root = Path.join(web_path, "priv/static")
    File.mkdir_p!(static_root)

    runner = fn
      "mix", ["phx.digest.clean", "--all", "--output", ^static_root], _opts ->
        {IO.stream(), 9}
    end

    assert_raise Mix.Error, ~r/mix failed \(9\): see streamed command output/, fn ->
      FinalArtifact.build_web_assets(%Mix.Release{path: Path.join(root, "release")},
        web_path: web_path,
        tracked_logical_gzip_paths: [],
        command_runner: runner
      )
    end
  end

  test "macOS patch copies only a measured OpenSSL edge and verifies loader-relative closure",
       %{root: root} do
    release_root = Path.join(root, "release")
    nif_dir = Path.join(release_root, "lib/crypto-5.9/priv/lib")
    source = Path.join(root, "host/libcrypto.3.dylib")
    nif = Path.join(nif_dir, "crypto.so")
    destination = Path.join(nif_dir, "libcrypto.3.dylib")
    File.mkdir_p!(nif_dir)
    File.mkdir_p!(Path.dirname(source))
    File.write!(nif, "nif")
    File.write!(source, "measured openssl")

    runner = openssl_runner(nif, source, destination)

    assert %{
             required?: true,
             libraries: ["lib/crypto-5.9/priv/lib/libcrypto.3.dylib"],
             consumers: ["lib/crypto-5.9/priv/lib/crypto.so"]
           } = FinalArtifact.patch_macos_openssl_tree!(release_root, command_runner: runner)

    assert File.read!(destination) == "measured openssl"
    assert_receive {:openssl_command, :rewrite, ^nif, ^source}
    assert_receive {:openssl_command, :stable_id, ^destination}
    assert_receive {:openssl_command, :sign, ^destination}
    assert_receive {:openssl_command, :sign, ^nif}
    assert_receive {:openssl_command, :verify, ^destination}
    assert_receive {:openssl_command, :verify, ^nif}
  end

  test "Linux patch owns the exact SCTP runtime closure before license sealing", %{root: root} do
    release_root = Path.join(root, "release")
    source = Path.join(root, "host/libsctp.so.1.0.19")
    destination = Path.join(release_root, "native/lib/libsctp.so.1.0.19")
    link = Path.join(release_root, "native/lib/libsctp.so.1")
    File.mkdir_p!(Path.dirname(source))
    File.mkdir_p!(release_root)
    File.write!(source, "bookworm libsctp")

    runner = fn
      "readelf", ["-d", path], _opts when path in [source, destination] ->
        {"Dynamic section:\n 0x000000000000000e (SONAME) Library soname: [libsctp.so.1]\n", 0}
    end

    assert %{
             library: "native/lib/libsctp.so.1.0.19",
             soname_link: "native/lib/libsctp.so.1",
             package_version: "1.0.19+dfsg-2"
           } =
             FinalArtifact.patch_linux_sctp_tree!(release_root,
               source_path: source,
               package_version: "1.0.19+dfsg-2",
               command_runner: runner
             )

    assert File.read!(destination) == "bookworm libsctp"
    assert File.read_link!(link) == "libsctp.so.1.0.19"
    assert File.stat!(destination).mode |> Bitwise.band(0o777) == 0o755
  end

  test "Linux SCTP patch leaves non-Linux artifacts unchanged", %{root: root} do
    release = %Mix.Release{path: Path.join(root, "release")}
    File.mkdir_p!(release.path)

    assert ^release = FinalArtifact.patch_linux_sctp(release, os_type: {:unix, :darwin})
    refute File.exists?(Path.join(release.path, "native"))
  end

  test "Linux SCTP patch fails closed on source, version, SONAME, and destination drift",
       %{root: root} do
    source = Path.join(root, "host/libsctp.so.1.0.19")
    File.mkdir_p!(Path.dirname(source))
    File.write!(source, "bookworm libsctp")

    good_runner = fn "readelf", ["-d", _path], _opts ->
      {"0x000000000000000e (SONAME) Library soname: [libsctp.so.1]\n", 0}
    end

    wrong_soname_runner = fn "readelf", ["-d", _path], _opts ->
      {"0x000000000000000e (SONAME) Library soname: [libsctp.so.2]\n", 0}
    end

    version_root = Path.join(root, "version-release")
    File.mkdir_p!(version_root)

    assert_raise Mix.Error, ~r/requires Debian libsctp1 1\.0\.19\+dfsg-2/, fn ->
      FinalArtifact.patch_linux_sctp_tree!(version_root,
        source_path: source,
        package_version: "1.0.21+dfsg-1",
        command_runner: good_runner
      )
    end

    soname_root = Path.join(root, "soname-release")
    File.mkdir_p!(soname_root)

    assert_raise Mix.Error, ~r/SONAME must be libsctp\.so\.1/, fn ->
      FinalArtifact.patch_linux_sctp_tree!(soname_root,
        source_path: source,
        package_version: "1.0.19+dfsg-2",
        command_runner: wrong_soname_runner
      )
    end

    collision_root = Path.join(root, "collision-release")
    collision = Path.join(collision_root, "native/lib/libsctp.so.1.0.19")
    File.mkdir_p!(Path.dirname(collision))
    File.write!(collision, "different bytes")

    assert_raise Mix.Error, ~r/SCTP destination collision/, fn ->
      FinalArtifact.patch_linux_sctp_tree!(collision_root,
        source_path: source,
        package_version: "1.0.19+dfsg-2",
        command_runner: good_runner
      )
    end

    symlink_root = Path.join(root, "symlink-release")
    symlink_source = Path.join(root, "host/libsctp-link")
    File.mkdir_p!(symlink_root)
    File.ln_s!(source, symlink_source)

    assert_raise Mix.Error, ~r/source must be a regular file/, fn ->
      FinalArtifact.patch_linux_sctp_tree!(symlink_root,
        source_path: symlink_source,
        package_version: "1.0.19+dfsg-2",
        command_runner: good_runner
      )
    end
  end

  test "macOS patch makes the Exqlite NIF install name package-manager stable", %{root: root} do
    release_root = Path.join(root, "release")
    nif = Path.join(release_root, "lib/exqlite-0.39.0/priv/sqlite3_nif.so")
    absolute_id = "/Users/runner/work/exqlite/exqlite/_build/prod/lib/exqlite/priv/sqlite3_nif.so"
    File.mkdir_p!(Path.dirname(nif))
    File.write!(nif, "nif")
    Process.put(:exqlite_rewritten, false)

    runner = fn
      "otool", ["-D", ^nif], _opts ->
        install_name =
          if Process.get(:exqlite_rewritten),
            do: "@loader_path/sqlite3_nif.so",
            else: absolute_id

        {nif <> ":\n" <> install_name <> "\n", 0}

      "install_name_tool", ["-id", "@loader_path/sqlite3_nif.so", ^nif], _opts ->
        Process.put(:exqlite_rewritten, true)
        send(self(), {:exqlite_command, :rewrite, nif})
        {"", 0}

      "codesign", ["-f", "-s", "-", ^nif], _opts ->
        send(self(), {:exqlite_command, :sign, nif})
        {"", 0}

      "codesign", ["--verify", "--strict", ^nif], _opts ->
        send(self(), {:exqlite_command, :verify, nif})
        {"", 0}
    end

    assert %{install_name: "@loader_path/sqlite3_nif.so", rewritten?: true} =
             FinalArtifact.patch_macos_exqlite_install_name_tree!(release_root,
               command_runner: runner
             )

    assert_receive {:exqlite_command, :rewrite, ^nif}
    assert_receive {:exqlite_command, :sign, ^nif}
    assert_receive {:exqlite_command, :verify, ^nif}
  end

  test "macOS Exqlite patch rejects unexpected and ambiguous package paths", %{root: root} do
    release_root = Path.join(root, "release")
    nif = Path.join(release_root, "lib/exqlite-0.39.0/priv/sqlite3_nif.so")
    File.mkdir_p!(Path.dirname(nif))
    File.write!(nif, "nif")

    runner = fn "otool", ["-D", ^nif], _opts ->
      {nif <> ":\n@rpath/sqlite3_nif.so\n", 0}
    end

    assert_raise Mix.Error, ~r/unsupported Exqlite install name/, fn ->
      FinalArtifact.patch_macos_exqlite_install_name_tree!(release_root,
        command_runner: runner
      )
    end

    second = Path.join(release_root, "lib/exqlite-0.40.0/priv/sqlite3_nif.so")
    File.mkdir_p!(Path.dirname(second))
    File.write!(second, "nif")

    assert_raise Mix.Error, ~r/exactly one Exqlite NIF/, fn ->
      FinalArtifact.patch_macos_exqlite_install_name_tree!(release_root,
        command_runner: runner
      )
    end
  end

  test "macOS patch omits unmeasured OpenSSL bytes", %{root: root} do
    release_root = Path.join(root, "release")
    nif_dir = Path.join(release_root, "lib/crypto-5.9/priv/lib")
    nif = Path.join(nif_dir, "crypto.so")
    stale = Path.join(nif_dir, "libcrypto.3.dylib")
    File.mkdir_p!(nif_dir)
    File.write!(nif, "nif")
    File.write!(stale, "stale patch output")

    runner = fn
      "otool", ["-L", ^nif], _opts -> {otool_output(nif, ["/usr/lib/libSystem.B.dylib"]), 0}
      command, args, _opts -> flunk("unexpected command #{command} #{inspect(args)}")
    end

    assert %{required?: false, libraries: [], consumers: []} =
             FinalArtifact.patch_macos_openssl_tree!(release_root, command_runner: runner)

    refute File.exists?(stale)
  end

  test "macOS patch rejects symlink crypto leaves and ancestors before probing", %{root: root} do
    leaf_root = Path.join(root, "leaf-release")
    leaf_dir = Path.join(leaf_root, "lib/crypto-5.9/priv/lib")
    external_nif = Path.join(root, "external-crypto.so")
    File.mkdir_p!(leaf_dir)
    File.write!(external_nif, "nif")
    File.ln_s!(external_nif, Path.join(leaf_dir, "crypto.so"))

    never_run = fn command, args, _opts -> flunk("unexpected #{command} #{inspect(args)}") end

    assert_raise Mix.Error, ~r/unsafe release\/static path is symlink/, fn ->
      FinalArtifact.patch_macos_openssl_tree!(leaf_root, command_runner: never_run)
    end

    ancestor_root = Path.join(root, "ancestor-release")
    external_crypto = Path.join(root, "external-crypto-5.9")
    File.mkdir_p!(Path.join(external_crypto, "priv/lib"))
    File.write!(Path.join(external_crypto, "priv/lib/crypto.so"), "nif")
    File.mkdir_p!(Path.join(ancestor_root, "lib"))
    File.ln_s!(external_crypto, Path.join(ancestor_root, "lib/crypto-5.9"))

    assert_raise Mix.Error, ~r/unsafe release\/static path is symlink/, fn ->
      FinalArtifact.patch_macos_openssl_tree!(ancestor_root, command_runner: never_run)
    end
  end

  test "macOS patch rejects OpenSSL names outside the exact catalogued seam", %{root: root} do
    for name <- ["libcrypto.1.1.dylib", "libssl.3.dylib"] do
      release_root = Path.join(root, name)
      nif_dir = Path.join(release_root, "lib/crypto-5.9/priv/lib")
      nif = Path.join(nif_dir, "crypto.so")
      File.mkdir_p!(nif_dir)
      File.write!(nif, "nif")

      runner = fn "otool", ["-L", ^nif], _opts ->
        {otool_output(nif, [Path.join(root, name)]), 0}
      end

      assert_raise Mix.Error,
                   ~r/unsupported OpenSSL dependency .*v1\.2\.5 permits only libcrypto\.3\.dylib/,
                   fn ->
                     FinalArtifact.patch_macos_openssl_tree!(release_root,
                       command_runner: runner
                     )
                   end
    end
  end

  test "macOS patch rejects @rpath OpenSSL edges", %{root: root} do
    release_root = Path.join(root, "rpath-release")
    nif_dir = Path.join(release_root, "lib/crypto-5.9/priv/lib")
    nif = Path.join(nif_dir, "crypto.so")
    File.mkdir_p!(nif_dir)
    File.write!(nif, "nif")
    File.write!(Path.join(nif_dir, "libcrypto.3.dylib"), "openssl")

    runner = fn "otool", ["-L", ^nif], _opts ->
      {otool_output(nif, ["@rpath/libcrypto.3.dylib"]), 0}
    end

    assert_raise Mix.Error, ~r/@rpath dependency is unsupported in v1\.2\.5/, fn ->
      FinalArtifact.patch_macos_openssl_tree!(release_root, command_runner: runner)
    end
  end

  test "macOS patch rejects loader paths outside the exact catalogued location", %{root: root} do
    release_root = Path.join(root, "loader-release")
    nif_dir = Path.join(release_root, "lib/crypto-5.9/priv/lib")
    nif = Path.join(nif_dir, "crypto.so")
    nested = Path.join(nif_dir, "nested/libcrypto.3.dylib")
    File.mkdir_p!(Path.dirname(nested))
    File.write!(nif, "nif")
    File.write!(nested, "openssl")

    runner = fn "otool", ["-L", ^nif], _opts ->
      {otool_output(nif, ["@loader_path/nested/libcrypto.3.dylib"]), 0}
    end

    assert_raise Mix.Error, ~r/unsupported OpenSSL loader path/, fn ->
      FinalArtifact.patch_macos_openssl_tree!(release_root, command_runner: runner)
    end
  end

  test "macOS patch rejects a different-byte destination collision", %{root: root} do
    release_root = Path.join(root, "collision-release")
    nif_dir = Path.join(release_root, "lib/crypto-5.9/priv/lib")
    source = Path.join(root, "host/libcrypto.3.dylib")
    nif = Path.join(nif_dir, "crypto.so")
    destination = Path.join(nif_dir, "libcrypto.3.dylib")
    File.mkdir_p!(nif_dir)
    File.mkdir_p!(Path.dirname(source))
    File.write!(nif, "nif")
    File.write!(source, "measured")
    File.write!(destination, "different")

    runner = fn
      "otool", ["-L", ^nif], _opts -> {otool_output(nif, [source]), 0}
      command, args, _opts -> flunk("unexpected #{command} #{inspect(args)}")
    end

    assert_raise Mix.Error, ~r/OpenSSL destination collision/, fn ->
      FinalArtifact.patch_macos_openssl_tree!(release_root, command_runner: runner)
    end

    assert File.read!(destination) == "different"
  end

  test "OpenSSL probes capture real System.cmd output instead of a streaming accumulator",
       %{root: root} do
    release_root = Path.join(root, "release")
    nif_dir = Path.join(release_root, "lib/crypto-5.9/priv/lib")
    nif = Path.join(nif_dir, "crypto.so")
    library = Path.join(nif_dir, "libcrypto.3.dylib")
    File.mkdir_p!(nif_dir)
    File.write!(nif, "nif")
    File.write!(library, "openssl")

    runner = fn
      "otool", ["-L", ^nif], opts ->
        System.cmd("printf", [otool_output(nif, ["@loader_path/libcrypto.3.dylib"])], opts)

      "otool", ["-L", ^library], opts ->
        System.cmd(
          "printf",
          [
            otool_output(library, ["@loader_path/libcrypto.3.dylib", "/usr/lib/libSystem.B.dylib"])
          ],
          opts
        )

      "otool", ["-D", ^library], opts ->
        System.cmd("printf", [library <> ":\n@loader_path/libcrypto.3.dylib\n"], opts)

      "codesign", _args, opts ->
        System.cmd("true", [], opts)
    end

    assert %{required?: true, libraries: [_], consumers: [_]} =
             FinalArtifact.patch_macos_openssl_tree!(release_root, command_runner: runner)
  end

  test "license sealing uses the resolved closure and verifies the external manifest digest",
       %{root: root} do
    release = %Mix.Release{
      path: Path.join(root, "release"),
      applications: %{
        kernel: [vsn: ~c"10.3"],
        allbert_assist: [vsn: ~c"1.2.1"]
      }
    }

    assert ^release =
             FinalArtifact.finalize_license_evidence(release,
               repo_root: root,
               licenses_module: FakeLicenses
             )

    assert_receive {:license_call, :load_catalog, [repo_root: ^root]}
    assert_receive {:license_call, :build_target}

    assert_receive {:license_call, :finalize, %{"catalog" => true}, applications, target,
                    [repo_root: ^root, release_root: release_root]}

    assert release_root == release.path

    assert applications == [
             %{"application" => "allbert_assist", "version" => "1.2.1"},
             %{"application" => "kernel", "version" => "10.3"}
           ]

    assert target == %{
             "triple" => "macos-arm64",
             "otp_version" => "29.0.1",
             "elixir_version" => "1.19.5",
             "erts_version" => "17.0.1"
           }

    assert_receive {:license_call, :verify,
                    [release_root: ^release_root, manifest_sha256: @manifest_sha256]}
  end

  defp write_asset_manifest!(static_root, logical_path, contents) do
    digest = contents |> :erlang.md5() |> Base.encode16(case: :lower)
    extension = Path.extname(logical_path)
    digested_path = Path.rootname(logical_path) <> "-" <> digest <> extension
    logical_file = Path.join(static_root, logical_path)
    digested_file = Path.join(static_root, digested_path)
    File.mkdir_p!(Path.dirname(logical_file))
    File.write!(logical_file, contents)
    File.write!(digested_file, contents)

    manifest = %{
      "version" => 1,
      "latest" => %{logical_path => digested_path},
      "digests" => %{
        digested_path => %{
          "logical_path" => logical_path,
          "mtime" => 0,
          "size" => byte_size(contents),
          "digest" => digest,
          "sha512" => contents |> then(&:crypto.hash(:sha512, &1)) |> Base.encode64()
        }
      }
    }

    File.write!(Path.join(static_root, "cache_manifest.json"), Jason.encode!(manifest))
    digested_path
  end

  defp write_logical_gzip!(static_root, logical_path, contents, mode) do
    source = Path.join(static_root, logical_path)
    gzip = source <> ".gz"
    File.mkdir_p!(Path.dirname(source))
    File.write!(source, contents)
    compressed = :zlib.gzip(contents)
    File.write!(gzip, compressed)
    File.chmod!(gzip, mode)
    compressed
  end

  defp openssl_runner(nif, source, destination) do
    Process.put({:stable_id, destination}, false)

    fn
      "otool", ["-L", ^nif], _opts ->
        dependency =
          if Process.get({:rewritten, nif}),
            do: "@loader_path/libcrypto.3.dylib",
            else: source

        {otool_output(nif, [dependency, "/usr/lib/libSystem.B.dylib"]), 0}

      "otool", ["-L", ^destination], _opts ->
        {otool_output(destination, ["/usr/lib/libSystem.B.dylib"]), 0}

      "otool", ["-D", ^destination], _opts ->
        install_id =
          if Process.get({:stable_id, destination}),
            do: "@loader_path/libcrypto.3.dylib",
            else: source

        {destination <> ":\n" <> install_id <> "\n", 0}

      "install_name_tool", ["-change", ^source, "@loader_path/libcrypto.3.dylib", ^nif], _opts ->
        Process.put({:rewritten, nif}, true)
        send(self(), {:openssl_command, :rewrite, nif, source})
        {"", 0}

      "install_name_tool", ["-id", "@loader_path/libcrypto.3.dylib", ^destination], _opts ->
        Process.put({:stable_id, destination}, true)
        send(self(), {:openssl_command, :stable_id, destination})
        {"", 0}

      "codesign", ["-f", "-s", "-", path], _opts ->
        send(self(), {:openssl_command, :sign, path})
        {"", 0}

      "codesign", ["--verify", "--strict", path], _opts ->
        send(self(), {:openssl_command, :verify, path})
        {"", 0}
    end
  end

  defp otool_output(binary, dependencies) do
    rows = Enum.map_join(dependencies, "\n", &("\t" <> &1 <> " (compatibility version 1.0.0)"))
    binary <> ":\n" <> rows <> "\n"
  end
end
