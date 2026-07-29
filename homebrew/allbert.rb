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
      url "https://github.com/lexlapax/allbert-assist/releases/download/v1.2.6/allbert-v1.2.6-macos-arm64.tar.gz"
      sha256 "ff5a17b116e3e21cf7b8321e6f4166216e64c76778d5d9b709e5b6d054e8886f"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/lexlapax/allbert-assist/releases/download/v1.2.6/allbert-v1.2.6-linux-x64.tar.gz"
      sha256 "efa501276108335551d497ef3477cc12844cd888b4e60ecdc1b774119063726e"
    end
    on_arm do
      url "https://github.com/lexlapax/allbert-assist/releases/download/v1.2.6/allbert-v1.2.6-linux-arm64.tar.gz"
      sha256 "a4fdc202d8d48299caeb1a0de0d0e18133afe03985ea5f879e692cdb11197020"
    end
  end

  def install
    # Homebrew rewrites and re-signs this bundle's absolute build-time Mach-O
    # install name after install(), which would invalidate the packaged manifest.
    # Preserve the accepted bytes until post_install runs after that relocation.
    managed_nif = Dir["lib/exqlite-*/priv/sqlite3_nif.so"].fetch(0)
    system "tar", "-czf", "allbert-managed-nif.tar.gz", managed_nif
    pkgshare.install "allbert-managed-nif.tar.gz"
    libexec.install Dir["*"]
    # Homebrew otherwise relocates release metafiles out of libexec after this
    # method returns. Keep the runtime evidence regular and complete there while
    # exposing the conventional top-level paths as relative links.
    prefix.install_symlink libexec/"LICENSE", libexec/"NOTICE"
    (bin/"allbert").write_env_script libexec/"bin/allbert", SHELL: "/bin/sh"
  end

  def post_install
    system "tar", "-xzf", pkgshare/"allbert-managed-nif.tar.gz", "-C", libexec
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
