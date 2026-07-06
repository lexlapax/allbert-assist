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

  test "the release workflow publishes checksums and attaches to the release" do
    body = File.read!(@workflow)
    assert body =~ "sha256sum"
    assert body =~ "SHA256SUMS"
    assert body =~ "gh release upload"
    # Native per-target matrix (no cross-compilation).
    assert body =~ "macos-arm64" and body =~ "linux-x64" and body =~ "linux-arm64"
    assert body =~ "smoke"
  end
end
