# Allbert Homebrew formula template. Bumped per release and copied to the tap repo
# (lexlapax/homebrew-allbert) at release time; kept here as the source of
# truth. A FORMULA (not a cask) because Allbert wants `brew services` support
# for `allbert serve` (cask has no service block) and ships prebuilt
# per-platform binaries (the HashiCorp-tap pattern; homebrew-core's
# no-source-builds rule does not apply to third-party taps).
#
# The url/sha256 blocks are filled from the GitHub release + SHA256SUMS at
# release time (M8 / CI). Placeholders below are replaced by the release job.
class Allbert < Formula
  desc "Local-first personal AI assistant runtime, CLI, and web workspace"
  homepage "https://github.com/lexlapax/allbert-assist"
  license "Apache-2.0"

  depends_on "node"

  on_macos do
    on_arm do
      url "https://github.com/lexlapax/allbert-assist/releases/download/v1.4.0/allbert-v1.4.0-macos-arm64.tar.gz"
      sha256 "32931a29f2200e13a29eaa1eaf564c3414432957760a34fb9841149b1b8ea039"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/lexlapax/allbert-assist/releases/download/v1.4.0/allbert-v1.4.0-linux-x64.tar.gz"
      sha256 "49a2b40a39406da68b90da02d8d62b7ca39cd2dd8266b2c50c87188ab3cf47be"
    end
    on_arm do
      url "https://github.com/lexlapax/allbert-assist/releases/download/v1.4.0/allbert-v1.4.0-linux-arm64.tar.gz"
      sha256 "729d2150b8de2ee88efba80df0c4cab9bf324447596299bcb338a3a7448600dc"
    end
  end

  def install
    managed_machos = [
      Dir["lib/crypto-*/priv/lib/libcrypto.3.dylib"],
      Dir["lib/exqlite-*/priv/sqlite3_nif.so"],
    ]
    odie "expected exactly two managed Mach-O payloads" unless managed_machos.all?(&:one?)

    sealed_evidence = %w[
      LICENSE
      NOTICE
      THIRD-PARTY-LICENSES.md
      THIRD-PARTY-MANIFEST.json
      licenses
    ]
    sealed_evidence_files = sealed_evidence.take(4) + Dir["licenses/**/*"].select { |path| File.file?(path) }
    sealed_evidence_directories = ["licenses"] + Dir["licenses/**/*"].select { |path| File.directory?(path) }

    # Homebrew's initial extraction honors the invoking umask. Canonicalize the
    # bounded generated evidence before preserving it, so both the archive and
    # the installed license verifier see the release's sealed 0644/0755 modes.
    File.chmod(0644, *sealed_evidence_files)
    File.chmod(0755, *sealed_evidence_directories)

    managed_payloads = managed_machos.flatten + sealed_evidence

    system "tar", "-czf", "allbert-managed-payloads.tar.gz", *managed_payloads
    pkgshare.install "allbert-managed-payloads.tar.gz"
    libexec.install Dir["*"]
    # Homebrew otherwise relocates release metafiles out of libexec after this
    # method returns. Keep the runtime evidence regular and complete there while
    # exposing the conventional top-level paths as relative links.
    prefix.install_symlink libexec/"LICENSE", libexec/"NOTICE"
    (bin/"allbert").write_env_script libexec/"bin/allbert", SHELL: "/bin/sh"
  end

  def post_install
    system "tar", "-xpzf", pkgshare/"allbert-managed-payloads.tar.gz", "-C", libexec
  end

  def caveats
    <<~EOS
      Browser/research is optional and its runtime is intentionally not bundled.
      Install Playwright into a host-managed directory without downloading a browser:

        PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install \
          --prefix "$HOME/.local/share/allbert/playwright-1.58.2" \
          --ignore-scripts --no-audit --no-fund --no-save playwright@1.58.2
        allbert admin settings set browser.driver.node_module_path \
          "$HOME/.local/share/allbert/playwright-1.58.2/node_modules"
        allbert admin settings set browser.driver.version_pin 1.58.2
        allbert admin settings set browser.driver.binary_path \
          /absolute/path/to/your/OS-managed/chromium-or-chrome

      Node is a formula dependency. Chromium/Chrome remains an OS-managed host
      package. Allbert never runs npm or a browser downloader at runtime.
    EOS
  end

  service do
    run [opt_bin/"allbert", "serve"]
    keep_alive true
    log_path var/"log/allbert.log"
    error_log_path var/"log/allbert.log"
  end

  test do
    assert_match "allbert", shell_output("#{bin}/allbert eval 'IO.puts(:allbert)'")
    assert_match "\"schema_version\"", shell_output("#{bin}/allbert licenses --json")
  end
end
