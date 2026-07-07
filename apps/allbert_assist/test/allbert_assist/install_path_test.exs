defmodule AllbertAssist.InstallPathTest do
  @moduledoc """
  v0.62 M2 — the install/uninstall scripts and Homebrew formula are
  syntactically valid and honor the distribution-trust contract: checksum
  verification, a manifest-driven uninstall, and Allbert Home never touched
  absent `--purge`.
  """
  use ExUnit.Case, async: true

  @moduletag :install_path

  @repo_root Path.expand("../../../../", __DIR__)
  @install Path.join(@repo_root, "scripts/install/install.sh")
  @uninstall Path.join(@repo_root, "scripts/install/uninstall.sh")
  @formula Path.join(@repo_root, "homebrew/allbert.rb")
  @workflow Path.join(@repo_root, ".github/workflows/release-artifacts.yml")
  @root_mix Path.join(@repo_root, "mix.exs")
  @overlay Path.join(@repo_root, "rel/overlays/bin/allbert-dispatch")
  @smoke Path.join(@repo_root, "scripts/smoke/artifact_smoke.sh")
  @service Path.join(@repo_root, "apps/allbert_assist/lib/allbert_assist/service.ex")

  test "install.sh parses under /bin/sh and honors the trust contract" do
    assert File.exists?(@install)
    assert {_, 0} = System.cmd("sh", ["-n", @install], stderr_to_stdout: true)

    body = File.read!(@install)
    # Checksum verification against the release SHA256SUMS.
    assert body =~ "SHA256SUMS"
    assert body =~ "checksum mismatch"
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
  end

  test "uninstall.sh parses and preserves Allbert Home absent --purge" do
    assert {_, 0} = System.cmd("sh", ["-n", @uninstall], stderr_to_stdout: true)

    body = File.read!(@uninstall)
    assert body =~ "install-manifest"
    assert body =~ "--purge"
    assert body =~ "Allbert Home preserved"
  end

  test "the Homebrew formula is a formula with a service block and per-platform urls" do
    body = File.read!(@formula)
    assert body =~ "class Allbert < Formula"
    # Formula (not cask) so `brew services` works for `allbert serve`.
    assert body =~ "service do"
    assert body =~ ~s{run [opt_bin/"allbert", "serve"]}
    # Per-platform prebuilt artifacts + checksums (placeholders filled at release).
    assert body =~ "macos-arm64" and body =~ "linux-x64" and body =~ "linux-arm64"
    assert body =~ "sha256"
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

  test "the smoke harness executes the shipped allbert and boots apps for the plugin probe" do
    smoke = File.read!(@smoke)
    # v0.62 M8.12: the smoke exercises the operator-style symlink
    # (<work>/bin/allbert -> <release>/bin/allbert), not the release bin directly,
    # so a symlink-resolution regression is caught in CI.
    assert smoke =~ ~s(ln -sf "$REL_ROOT/bin/allbert" "$WORK/bin/allbert")
    assert smoke =~ ~s(BIN="$WORK/bin/allbert")
    # The plugin-count eval starts the OTP apps (bare `eval` only loads them, so
    # the App.Registry GenServer would be down and the count would be 0).
    assert smoke =~ "Application.ensure_all_started(:allbert_assist)"
    # Proves attach and health against the live daemon, not just boot.
    assert smoke =~ "/health" and smoke =~ "attach"
  end

  test "the release workflow publishes checksums and attaches to the release" do
    body = File.read!(@workflow)
    assert body =~ "sha256sum"
    assert body =~ "SHA256SUMS"
    # v0.62 M8.25: the release must be CREATED before assets are uploaded — a
    # pushed tag doesn't auto-create a Release, so `gh release upload` alone would
    # fail on the first tag. Prerelease-aware for rc-tag build tests.
    assert body =~ "gh release create" and body =~ "--verify-tag"
    assert body =~ "--prerelease"
    assert body =~ "gh release upload"
    # Native per-target matrix (no cross-compilation).
    assert body =~ "macos-arm64" and body =~ "linux-x64" and body =~ "linux-arm64"
    assert body =~ "smoke"
    # v0.62 M8.17: publish is gated on the Linux rehearsal, and the version-less
    # alias is derived from the known target suffix (not a version regex that a
    # prerelease `-rc1` hyphen would mangle).
    assert body =~ "needs: [build, linux-rehearsal]"
    assert body =~ ~s{cp "$f" "allbert-$target.tar.gz"}
  end
end
