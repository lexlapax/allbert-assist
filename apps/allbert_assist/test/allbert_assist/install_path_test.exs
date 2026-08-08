defmodule AllbertAssist.InstallPathTest do
  @moduledoc """
  v0.62 M2 — the install/uninstall scripts and Homebrew formula are
  syntactically valid and honor the distribution-trust contract: checksum
  verification, a manifest-driven uninstall, and Allbert Home never touched
  absent `--purge`.
  """
  use ExUnit.Case, async: true
  @moduletag :external_runtime_serial

  alias AllbertAssist.SecurityFixtures.AssertBinding

  @moduletag :install_path

  @repo_root Path.expand("../../../../", __DIR__)
  @install Path.join(@repo_root, "scripts/install/install.sh")
  @uninstall Path.join(@repo_root, "scripts/install/uninstall.sh")
  @formula Path.join(@repo_root, "homebrew/allbert.rb")
  @fill_sha256 Path.join(@repo_root, "homebrew/fill-sha256.sh")
  @workflow Path.join(@repo_root, ".github/workflows/release-artifacts.yml")
  @stage_script Path.join(@repo_root, "scripts/release/stage_artifacts.sh")
  @promote_script Path.join(@repo_root, "scripts/release/promote_artifacts.sh")
  @root_mix Path.join(@repo_root, "mix.exs")
  @overlay Path.join(@repo_root, "rel/overlays/bin/allbert-dispatch")
  @smoke Path.join(@repo_root, "scripts/smoke/artifact_smoke.sh")
  @browser_runtime_smoke Path.join(@repo_root, "scripts/smoke/browser_runtime_boundary_smoke.sh")
  @linux_rehearsal Path.join(@repo_root, "scripts/smoke/linux_rehearsal.sh")
  @release_env Path.join(@repo_root, "rel/env.sh.eex")
  @service Path.join(@repo_root, "apps/allbert_assist/lib/allbert_assist/service.ex")

  test "install.sh parses under /bin/sh and honors the trust contract" do
    assert File.exists?(@install)
    assert {_, 0} = System.cmd("sh", ["-n", @install], stderr_to_stdout: true)

    body = File.read!(@install)
    # Checksum verification against the release SHA256SUMS.
    assert body =~ "SHA256SUMS"
    assert body =~ "SHA256SUMS.cosign.bundle"
    assert body =~ "cosign verify-blob"
    assert body =~ "Refusing to install without signature verification."
    assert body =~ "brew install cosign"
    assert body =~ "docs.sigstore.dev/cosign/installation"
    assert body =~ "https://token.actions.githubusercontent.com"
    assert body =~ "release-artifacts.yml@refs/tags"

    assert body =~
             "--certificate-identity \"https://github.com/lexlapax/allbert-assist/.github/workflows/release-artifacts.yml@refs/tags/$RELEASE_TAG\""

    refute body =~ "--certificate-identity-regexp"
    assert body =~ "RELEASE_TAG=\"$VERSION\""
    assert body =~ "releases/latest"
    assert body =~ "%{url_effective}"
    assert body =~ "releases/download/$RELEASE_TAG"
    assert body =~ "ALLBERT_RELEASE_TAG"
    assert body =~ "checksum mismatch"
    assert body =~ "allbert admin service install --dry-run"
    assert body =~ "allbert admin confirmations approve <ID>"
    assert body =~ "allbert serve --open"
    assert body =~ "main() {" and body =~ "\nmain \"$@\""
    # Only Tier-1 targets; WSL2 note for Windows.
    assert body =~ "macos-arm64" and body =~ "linux-x64" and body =~ "linux-arm64"
    assert body =~ "WSL2"
    # Writes an uninstall manifest; never touches Allbert Home.
    assert body =~ "install-manifest"
    assert body =~ "never touched"
    # v0.62 M8.17: a bare ALLBERT_VERSION is normalized to the v-prefixed form so
    # it doesn't double-404, and the checksum is looked up by exact awk field.
    assert body =~ ~s(VERSION="v${VERSION#v}")
    assert body =~ ~s{awk -v f="$artifact" '$2 == f}

    workflow = File.read!(@workflow)
    promoter = File.read!(@promote_script)
    assert promoter =~ "sign-blob"
    refute workflow =~ "continue-on-error: true"

    AssertBinding.check!("trusted-install-artifact-verification-001", [
      :cosign_bundle_required,
      :checksum_signature_verified,
      :workflow_signing_hard_gate
    ])

    AssertBinding.check!("trusted-install-guided-verifier-bootstrap-001", [
      :missing_cosign_fails_closed,
      :install_guidance_present,
      :no_warning_continue_path
    ])
  end

  test "uninstall.sh parses and preserves Allbert Home absent --purge" do
    assert {_, 0} = System.cmd("sh", ["-n", @uninstall], stderr_to_stdout: true)

    body = File.read!(@uninstall)
    assert body =~ "install-manifest"
    assert body =~ "--purge"
    assert body =~ "Allbert Home preserved"
  end

  @tag :tmp_dir
  test "release environment prefers an artifact-local native library closure", %{tmp_dir: tmp_dir} do
    release_root = Path.join(tmp_dir, "release")
    File.mkdir_p!(Path.join(release_root, "native/lib"))

    script = ~S"""
    RELEASE_ROOT="$TEST_RELEASE_ROOT"
    LD_LIBRARY_PATH="/host/lib"
    export RELEASE_ROOT LD_LIBRARY_PATH
    . "$TEST_RELEASE_ENV"
    printf '%s\n' "$LD_LIBRARY_PATH"
    """

    assert {output, 0} =
             System.cmd("sh", ["-c", script],
               env: [
                 {"TEST_RELEASE_ROOT", release_root},
                 {"TEST_RELEASE_ENV", @release_env}
               ],
               stderr_to_stdout: true
             )

    assert String.trim(output) == Path.join(release_root, "native/lib") <> ":/host/lib"
  end

  test "the Homebrew formula is a formula with a service block and per-platform urls" do
    body = File.read!(@formula)
    project = project_version()

    assert body =~ "class Allbert < Formula"
    assert body =~ ~s(depends_on "node")
    assert body =~ "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1"
    assert body =~ "playwright@1.58.2"
    assert body =~ "browser.driver.node_module_path"
    assert body =~ "browser.driver.binary_path"
    assert body =~ ~s(prefix.install_symlink libexec/"LICENSE", libexec/"NOTICE")
    assert body =~ ~S(#{bin}/allbert licenses --json)
    assert body =~ "allbert-managed-payloads.tar.gz"
    assert body =~ "libcrypto.3.dylib"
    assert body =~ "sqlite3_nif.so"
    assert body =~ "managed_payloads = managed_machos.flatten + sealed_evidence"
    assert body =~ "File.chmod(0644, *sealed_evidence_files)"
    assert body =~ "File.chmod(0755, *sealed_evidence_directories)"
    assert body =~ ~s(system "tar", "-xpzf", pkgshare/"allbert-managed-payloads.tar.gz")

    for evidence_root <- [
          "LICENSE",
          "NOTICE",
          "THIRD-PARTY-LICENSES.md",
          "THIRD-PARTY-MANIFEST.json",
          "licenses"
        ] do
      assert body =~ evidence_root
    end

    assert body =~ ~s(def post_install)

    # Homebrew derives this formula's version from the release URLs. An explicit
    # version is redundant and rejected by current strict audit.
    refute body =~ ~r/^\s*version /m

    formula_versions =
      ~r{releases/download/v([^/]+)/allbert-v[^/]+-(?:macos-arm64|linux-x64|linux-arm64)\.tar\.gz}
      |> Regex.scan(body, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    assert [formula_version] = formula_versions

    # Release-model invariant: the repository formula (synced to the tap after
    # publication) may lag
    # the project version ONLY when the CHANGELOG section for the project version
    # DOCUMENTS the lag and names the formula's version as the surviving packaged
    # Latest. Two legitimate lag reasons are accepted (v1.0.3 M9 broadening — the
    # original test recognized only the first):
    #   (a) a `[skip-artifacts]` source/docs tag that PERMANENTLY does not move
    #       the packaged line (v1.0.1, v1.0.2); or
    #   (b) an RC-WINDOW lag on a binary release, where the formula stays on the
    #       prior packaged Latest through the RC and the tap is FILLED to the
    #       project version at tag/publish time (v1.0.3 catch-up); or
    #   (c) a published binary failed post-publication acceptance and an
    #       immutable hotfix owns the repair. The public tap names the failed
    #       binary while this repository's formula template stays on its last
    #       reconciled value until the hotfix publishes real checksums.
    # Branch (b) is
    #       temporary lag that M10 closes, not a permanent divergence. The
    #       changelog must carry the exact PRE-PUBLICATION ONLY marker so this
    #       exception cannot be described as a completed release state.
    # The invariant's protection — a lagging formula must be explained in the
    # CHANGELOG, never silently shipped — holds in both cases; only the accepted
    # explanation is broadened.
    if formula_version != project do
      changelog_section =
        @repo_root
        |> Path.join("CHANGELOG.md")
        |> File.read!()
        |> String.split(~r/^## /m)
        |> Enum.find(&String.starts_with?(&1, "v#{project}"))

      assert changelog_section, "CHANGELOG has no section for the project version v#{project}"

      # Collapse whitespace so a documentation phrase is recognized regardless of
      # where the CHANGELOG's prose line-wrap falls — the invariant is about the
      # words being present, not their line breaks.
      normalized = changelog_section |> String.replace(~r/\s+/, " ")

      # Each branch names formula_version as the surviving packaged Latest, in
      # its own phrasing — the shared protection is preserved, not dropped.
      skip_artifacts_tag? =
        normalized =~ "[skip-artifacts]" and
          normalized =~ "`v#{formula_version}` remains"

      binary_rc_fill? =
        normalized =~ "packaged Latest #{formula_version}" and
          normalized =~ "tap is filled" and
          normalized =~ "#{formula_version} → #{project}" and
          normalized =~ "Formula state: PRE-PUBLICATION ONLY" and
          normalized =~ "that filled formula is synced back into the repository"

      immutable_hotfix_recovery? =
        case Regex.run(~r/public tap is (\d+\.\d+\.\d+)/i, normalized) do
          [_, tap_version] ->
            tap_version not in [formula_version, project] and
              (normalized =~ "published v#{tap_version}" or
                 normalized =~ "Published v#{tap_version}") and
              normalized =~ "repository formula remains on #{formula_version}" and
              normalized =~ "tap moves #{tap_version} → #{project}" and
              normalized =~ "that filled formula is synced back into the repository" and
              normalized =~ "accepted corrective closeout"

          _other ->
            false
        end

      assert skip_artifacts_tag? or binary_rc_fill? or immutable_hotfix_recovery?,
             "CHANGELOG v#{project} must document the formula lag as either a " <>
               "[skip-artifacts] source tag (`v#{formula_version}` remains) or a " <>
               "binary catch-up that fills the formula #{formula_version} → " <>
               "#{project} at publish (packaged Latest #{formula_version}) and " <>
               "is explicitly marked PRE-PUBLICATION ONLY until repository " <>
               "formula convergence, or an immutable-hotfix recovery that " <>
               "names both the public tap and repository formula versions"
    end

    # Formula (not cask) so `brew services` works for `allbert serve`.
    assert body =~ "service do"
    assert body =~ ~s{run [opt_bin/"allbert", "serve"]}
    # Per-platform prebuilt artifacts + checksums (placeholders filled at release);
    # url/version consistency is asserted against the formula's own version.
    for target <- ["macos-arm64", "linux-x64", "linux-arm64"] do
      assert body =~ "allbert-v#{formula_version}-#{target}.tar.gz"
      assert body =~ "releases/download/v#{formula_version}"
    end

    assert body =~ "sha256"
    refute body =~ "v0.63.0"
  end

  test "the Homebrew payload restore preserves sealed evidence modes under restrictive umask" do
    root =
      Path.join(System.tmp_dir!(), "allbert-homebrew-modes-#{System.unique_integer([:positive])}")

    source = Path.join(root, "source")
    installed = Path.join(root, "installed")
    archive = Path.join(root, "managed-payloads.tar.gz")
    manifest = Path.join(source, "THIRD-PARTY-MANIFEST.json")
    catalog = Path.join([source, "licenses", "catalog.json"])

    File.mkdir_p!(Path.dirname(catalog))
    File.mkdir_p!(installed)
    File.write!(manifest, "{}\n")
    File.write!(catalog, "{}\n")
    # Homebrew's URL extraction has already applied the invoking umask before
    # the formula runs. The formula must establish the sealed release modes
    # before it creates its private preservation archive.
    File.chmod!(manifest, 0o600)
    File.chmod!(catalog, 0o600)
    File.chmod!(Path.dirname(catalog), 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    File.chmod!(manifest, 0o644)
    File.chmod!(catalog, 0o644)
    File.chmod!(Path.dirname(catalog), 0o755)

    assert {_, 0} =
             System.cmd(
               "tar",
               ["-czf", archive, "-C", source, "THIRD-PARTY-MANIFEST.json", "licenses"],
               stderr_to_stdout: true
             )

    File.cp!(manifest, Path.join(installed, "THIRD-PARTY-MANIFEST.json"))
    File.cp_r!(Path.join(source, "licenses"), Path.join(installed, "licenses"))
    File.chmod!(Path.join(installed, "THIRD-PARTY-MANIFEST.json"), 0o600)
    File.chmod!(Path.join([installed, "licenses", "catalog.json"]), 0o600)
    File.chmod!(Path.join(installed, "licenses"), 0o700)

    assert {_, 0} =
             System.cmd(
               "sh",
               ["-c", "umask 077; tar -xpzf \"$1\" -C \"$2\"", "sh", archive, installed],
               stderr_to_stdout: true
             )

    assert permission_mode(Path.join(installed, "THIRD-PARTY-MANIFEST.json")) == 0o644
    assert permission_mode(Path.join([installed, "licenses", "catalog.json"])) == 0o644
    assert permission_mode(Path.join(installed, "licenses")) == 0o755
  end

  test "fill-sha256 updates formula urls and checksums from release sums" do
    assert {_, 0} = System.cmd("sh", ["-n", @fill_sha256], stderr_to_stdout: true)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "allbert-fill-sha256-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    formula = Path.join(tmp, "allbert.rb")

    stale_formula =
      @formula
      |> File.read!()
      |> String.replace("v#{project_version()}", "v0.63.0")

    File.write!(formula, stale_formula)

    version = project_version()
    macos_arm64 = String.duplicate("a", 64)
    linux_x64 = String.duplicate("b", 64)
    linux_arm64 = String.duplicate("c", 64)
    sums = Path.join(tmp, "SHA256SUMS")

    File.write!(sums, """
    #{macos_arm64}  allbert-v#{version}-macos-arm64.tar.gz
    #{linux_x64}  allbert-v#{version}-linux-x64.tar.gz
    #{linux_arm64}  allbert-v#{version}-linux-arm64.tar.gz
    """)

    assert {output, 0} = System.cmd("sh", [@fill_sha256, sums, formula], stderr_to_stdout: true)
    assert output =~ "filled #{formula} for v#{version}"

    body = File.read!(formula)
    refute body =~ ~r/^\s*version /m
    refute body =~ "v0.63.0"
    refute body =~ "REPLACE_"

    assert body =~ "allbert-v#{version}-macos-arm64.tar.gz"
    assert body =~ "allbert-v#{version}-linux-x64.tar.gz"
    assert body =~ "allbert-v#{version}-linux-arm64.tar.gz"
    assert body =~ macos_arm64
    assert body =~ linux_x64
    assert body =~ linux_arm64
  end

  # v0.62 M8.6 (audit blocker): the operator dispatcher must be installed AS
  # `bin/allbert`. Without the install_dispatcher release step, `bin/allbert` is
  # the generated OTP launcher and `allbert admin …`/`allbert serve` fail with
  # "Unknown command" through the real installer/formula/service path. The
  # executable proof is the CI smoke harness (it runs the shipped binary); these
  # assertions guard the wiring so the class cannot silently regress.
  test "the release installs the operator dispatcher AS bin/allbert" do
    mix = File.read!(@root_mix)
    # The rename step is wired into the release pipeline.
    assert mix =~ "&install_dispatcher/1"
    assert mix =~ "defp install_dispatcher(release)"
    # It renames the generated launcher and moves the dispatcher onto bin/allbert.
    assert mix =~ ~s("allbert-release")

    overlay = File.read!(@overlay)
    # The dispatcher passthrough targets the renamed generated launcher — NOT
    # `$SELF_DIR/allbert` (which, once the overlay IS bin/allbert, self-loops).
    assert overlay =~ ~s(RELEASE_BIN="$SELF_DIR/allbert-release")
    refute overlay =~ ~s(RELEASE_BIN="$SELF_DIR/allbert\n")
    assert overlay =~ "AllbertAssist.CLI.Tui.launch!()"

    # v1.2.1 M0.b3: OTP raw input leaves Ctrl-C under the emulator break
    # posture unless the TUI launcher selects +Bc. Keep the override scoped to
    # the thin client and append it after any operator flags so it wins without
    # discarding them.
    assert overlay =~ ~s(ERL_AFLAGS="${ERL_AFLAGS:+$ERL_AFLAGS }+Bc")
    assert overlay =~ "ALLBERT_CLI_ATTACH_ONLY=1"
    assert overlay =~ "export ERL_AFLAGS ALLBERT_CLI_ATTACH_ONLY"

    assert Regex.match?(
             ~r/tui\).*ERL_AFLAGS=.*\+Bc.*AllbertAssist\.CLI\.Tui\.launch!/s,
             overlay
           )

    # v0.62 M8.12: the installer/Homebrew symlink `<prefix>/bin/allbert` at the
    # dispatcher; SELF_DIR MUST resolve through symlinks or it looks for
    # `allbert-release` beside the symlink (where it does not exist). Regression
    # guard for the bug the macOS install rehearsal caught.
    assert overlay =~ "readlink" and overlay =~ "[ -L"

    # v0.62 M8.17: the symlink-follow loop caps its hops so a cycle can't spin.
    assert overlay =~ "hops" and overlay =~ "too many symlink levels"

    # Every install surface invokes `allbert` (which the step makes the
    # dispatcher) — none hard-codes the generated launcher under another name.
    assert File.read!(@install) =~ ~s(ln -sf "$LIB_DIR/bin/allbert" "$BIN_DIR/allbert")
    assert File.read!(@formula) =~ ~s{run [opt_bin/"allbert", "serve"]}
    assert File.read!(@service) =~ ~S(ExecStart=#{binary} serve)
  end

  test "the release dispatcher scopes Ctrl-C posture to the TUI child" do
    release_bin = temp_release_root("tui-break-posture")
    dispatcher = Path.join(release_bin, "allbert")
    generated_launcher = Path.join(release_bin, "allbert-release")

    File.cp!(@overlay, dispatcher)
    File.chmod!(dispatcher, 0o700)

    File.write!(
      generated_launcher,
      ~S"""
      #!/bin/sh
      printf 'erl_aflags=%s\n' "${ERL_AFLAGS-unset}"
      printf 'attach_only=%s\n' "${ALLBERT_CLI_ATTACH_ONLY-unset}"
      printf 'argv=%s\n' "$*"
      """
    )

    File.chmod!(generated_launcher, 0o700)

    assert {tui_output, 0} =
             System.cmd(dispatcher, ["tui"],
               env: [{"ERL_AFLAGS", "+sbwt none"}],
               stderr_to_stdout: true
             )

    assert tui_output =~ "erl_aflags=+sbwt none +Bc"
    assert tui_output =~ "attach_only=1"
    assert tui_output =~ "argv=eval AllbertAssist.CLI.Tui.launch!()"

    assert {version_output, 0} =
             System.cmd(dispatcher, ["version"],
               env: [{"ERL_AFLAGS", "+sbwt none"}],
               stderr_to_stdout: true
             )

    assert version_output =~ "erl_aflags=+sbwt none"
    assert version_output =~ "attach_only=unset"
    refute version_output =~ "+Bc"
    assert version_output =~ "argv=version"
  end

  test "the smoke harness executes the shipped allbert and opens readiness for the plugin probe" do
    smoke = File.read!(@smoke)
    # v0.62 M8.12: the smoke exercises the operator-style symlink
    # (<work>/bin/allbert -> <release>/bin/allbert), not the release bin directly,
    # so a symlink-resolution regression is caught in CI.
    assert smoke =~ ~s(ln -sf "$REL_ROOT/bin/allbert" "$WORK/bin/allbert")
    assert smoke =~ ~s(BIN="$WORK/bin/allbert")
    # Runtime-bearing eval rows enter through the composition-owned bootstrap;
    # starting the residual app directly would bypass the M1.a3 readiness DAG.
    assert smoke =~
             "{:ok, _epoch} = AllbertAssist.Pack.ProductBootstrap.ensure_ready([]); " <>
               "IO.puts(length(AllbertAssist.App.Registry.registered_apps()))"

    refute smoke =~ "Application.ensure_all_started(:allbert_assist)"
    # Proves attach and health against the live daemon, not just boot.
    assert smoke =~ "/health" and smoke =~ "attach"

    # v1.0.4: the matrix must reject bundled Node/Playwright/Chromium and launch
    # the real doctor against explicitly provisioned host dependencies.
    assert smoke =~ "browser_runtime_boundary_smoke.sh"
    assert smoke =~ "smoke:browser_external_runtime PASS"
    assert smoke =~ "smoke:browser_doctor PASS"
    assert smoke =~ "smoke:browser_no_download PASS"
    assert smoke =~ "Schema.verify(conn, \"artifact-smoke\")"
    assert smoke =~ "smoke:sqlite_runtime PASS"
    assert smoke =~ "PLAYWRIGHT_NODE_PATH"
    assert smoke =~ "BROWSER_BINARY_PATH"
    assert smoke =~ "ALLBERT_PACKAGE_MANAGER_AUDIT"
    assert smoke =~ "package-manager invocation"
    assert smoke =~ "browser.navigation.timeout_ms 60000"
  end

  test "the browser runtime boundary accepts bridge source without external runtimes" do
    release_root = temp_release_root("external-browser-runtime")
    bridge = Path.join(release_root, "plugins/allbert.browser/priv/playwright_bridge")
    File.mkdir_p!(bridge)
    File.write!(Path.join(bridge, "bridge.js"), "// staged bridge\n")
    File.write!(Path.join(bridge, "package.json"), ~s({"dependencies":{"playwright":"1.58.2"}}))
    File.write!(Path.join(bridge, "package-lock.json"), ~s({"lockfileVersion":3}))

    assert {output, 0} =
             System.cmd("bash", [@browser_runtime_smoke, release_root], stderr_to_stdout: true)

    assert output =~ "browser-runtime-boundary:external PASS"
  end

  test "the browser runtime boundary rejects bundled Node packages and browsers" do
    release_root = temp_release_root("bundled-browser-runtime")
    bridge = Path.join(release_root, "plugins/allbert.browser/priv/playwright_bridge")
    File.mkdir_p!(bridge)
    File.write!(Path.join(bridge, "bridge.js"), "// staged bridge\n")
    File.write!(Path.join(bridge, "package.json"), ~s({"dependencies":{"playwright":"1.58.2"}}))
    File.write!(Path.join(bridge, "package-lock.json"), ~s({"lockfileVersion":3}))

    node_modules =
      Path.join(bridge, "node_modules/playwright-core/.local-browsers/chromium-123")

    File.mkdir_p!(node_modules)

    assert {output, status} =
             System.cmd("bash", [@browser_runtime_smoke, release_root], stderr_to_stdout: true)

    assert status != 0
    assert output =~ "browser-runtime-boundary:external FAIL"
    assert output =~ "must be supplied by the host"
  end

  test "release staging removes generated browser runtimes before packaging" do
    mix = File.read!(@root_mix)

    refute mix =~ "&build_browser_payload/1"
    refute mix =~ ~s|["install", "chromium"]|
    assert mix =~ "copy_runtime_tree_without!"
    assert mix =~ ~s|"playwright_bridge", "node_modules"|
    assert mix =~ "browser_runtime_boundary_smoke.sh"
  end

  test "the browser runtime boundary rejects staged host executables" do
    release_root = temp_release_root("bundled-browser-executable")
    bridge = Path.join(release_root, "plugins/allbert.browser/priv/playwright_bridge")
    executable = Path.join(release_root, "host-runtime/chromium")
    File.mkdir_p!(bridge)
    File.write!(Path.join(bridge, "bridge.js"), "// staged bridge\n")
    File.write!(Path.join(bridge, "package.json"), ~s({"dependencies":{"playwright":"1.58.2"}}))
    File.write!(Path.join(bridge, "package-lock.json"), ~s({"lockfileVersion":3}))
    File.mkdir_p!(Path.dirname(executable))
    File.write!(executable, "#!/bin/sh\n")
    File.chmod!(executable, 0o755)

    assert {output, status} =
             System.cmd("bash", [@browser_runtime_smoke, release_root], stderr_to_stdout: true)

    assert status != 0
    assert output =~ "browser-runtime-boundary:external FAIL"
    assert output =~ "host runtimes may not be staged"
  end

  test "the release workflow stages once and protected promotion publishes unchanged bytes" do
    body = File.read!(@workflow)
    stage = File.read!(@stage_script)
    promoter = File.read!(@promote_script)
    rehearsal = File.read!(@linux_rehearsal)

    assert {_, 0} = System.cmd("bash", ["-n", @linux_rehearsal], stderr_to_stdout: true)
    assert {_, 0} = System.cmd("bash", ["-n", @stage_script], stderr_to_stdout: true)
    assert {_, 0} = System.cmd("bash", ["-n", @promote_script], stderr_to_stdout: true)
    assert promoter =~ "SHA256SUMS"
    assert promoter =~ "sign-blob"
    refute body =~ "continue-on-error: true"
    refute promoter =~ "continue-on-error: true"
    # Operator machines create and fill one draft generation. Promotion never
    # creates, rebuilds, replaces, or clobbers product bytes.
    refute promoter =~ "release create"
    assert stage =~ "draft must have zero assets before complete-generation staging"
    assert stage =~ "exactly 13 candidate assets"
    assert promoter =~ "Content-Type: application/octet-stream"
    refute promoter =~ "--clobber"
    # The only target matrix is no-build qualification.
    assert body =~ "macos-arm64" and body =~ "linux-x64" and body =~ "linux-arm64"
    refute body =~ "mix release"
    refute body =~ "setup-beam@"
    refute body =~ "push:\n    tags:"
    assert body =~ "qualify-target"
    assert body =~ "collect-qualification"
    # Version-less aliases are derived from the exact candidate archives only
    # inside protected promotion.
    assert promoter =~ ~S|allbert-${target}.tar.gz|

    # Qualification consumes exact draft release-asset IDs and has no signing
    # authority. Only protected promotion receives id-token:write.
    assert body =~ "actions: read"
    assert body =~ "id-token: write"
    assert body =~ "sigstore/cosign-installer@6f9f17788090df1f26f669e9d70d6ae9567deba6"
    assert body =~ ~S|[ "$resolved_cosign" = v3.0.6 ]|
    assert body =~ "environment: release-promotion"
    assert body =~ "inputs.operation == 'qualification'"
    assert body =~ "inputs.operation == 'promotion'"
    assert promoter =~ "/immutable-releases"
    assert promoter =~ "published release did not become immutable"
    assert promoter =~ "OPERATOR_TUI_VALIDATION"
    assert promoter =~ "CONFIGURED_PROVIDER_VALIDATION"

    # The existing local Linux rehearsal remains a signed installer-path
    # fixture; it is no longer a hosted build dependency.
    assert rehearsal =~ "SHA256SUMS.cosign.bundle"
    assert rehearsal =~ "cosign sign-blob"
    assert rehearsal =~ "ALLBERT_REHEARSAL_SIGN_CHECKSUMS"

    assert rehearsal =~ "browser_runtime_boundary_smoke.sh"
    assert rehearsal =~ "linux-rehearsal:browser-doctor PASS"
    assert rehearsal =~ "PLAYWRIGHT_NODE_PATH"
    assert rehearsal =~ "BROWSER_BINARY_PATH"
    assert rehearsal =~ "ALLBERT_PACKAGE_MANAGER_AUDIT"
    assert rehearsal =~ "package-manager invocation"
    assert rehearsal =~ "browser.navigation.timeout_ms 60000"
    assert rehearsal =~ "ALLBERT_REHEARSAL_PREVERIFIED_STAGE"
    assert rehearsal =~ "install-preverified"
    assert rehearsal =~ "sha256sum"
  end

  defp project_version do
    @root_mix
    |> File.read!()
    |> then(&Regex.run(~r/version: "([^"]+)"/, &1))
    |> List.last()
  end

  defp permission_mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  defp temp_release_root(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "allbert-#{label}-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
