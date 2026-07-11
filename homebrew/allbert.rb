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
  version "0.65.0"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/lexlapax/allbert-assist/releases/download/v0.65.0/allbert-v0.65.0-macos-arm64.tar.gz"
      sha256 "REPLACE_MACOS_ARM64_SHA256"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/lexlapax/allbert-assist/releases/download/v0.65.0/allbert-v0.65.0-linux-x64.tar.gz"
      sha256 "REPLACE_LINUX_X64_SHA256"
    end
    on_arm do
      url "https://github.com/lexlapax/allbert-assist/releases/download/v0.65.0/allbert-v0.65.0-linux-arm64.tar.gz"
      sha256 "REPLACE_LINUX_ARM64_SHA256"
    end
  end

  def install
    libexec.install Dir["*"]
    (bin/"allbert").write_env_script libexec/"bin/allbert", SHELL: "/bin/sh"
  end

  service do
    run [opt_bin/"allbert", "serve"]
    keep_alive true
    log_path var/"log/allbert.log"
    error_log_path var/"log/allbert.log"
  end

  test do
    assert_match "allbert", shell_output("#{bin}/allbert eval 'IO.puts(:allbert)'")
  end
end
