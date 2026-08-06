defmodule AllbertAssist.DevGates.PreflightAttestationTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.DevGates.PreflightAttestation

  test "validation rejects every stale field and requires a clean release tree" do
    current = state()
    artifact = Map.merge(current, %{"status" => "passed"})

    assert :ok = PreflightAttestation.validate(artifact, current)
    assert :ok = PreflightAttestation.validate(artifact, current, clean_required?: true)

    for field <-
          ~w[head_sha worktree_content_digest mix_lock_digest gate_definition_digest elixir_version otp_release otp_version] do
      assert {:error, reasons} =
               PreflightAttestation.validate(Map.put(artifact, field, "changed"), current)

      assert "#{field} changed" in reasons
    end

    dirty = Map.put(current, "clean", false)
    dirty_artifact = Map.merge(dirty, %{"status" => "passed"})
    assert :ok = PreflightAttestation.validate(dirty_artifact, dirty)

    assert {:error, ["release evidence requires a clean worktree"]} =
             PreflightAttestation.validate(dirty_artifact, dirty, clean_required?: true)
  end

  test "content digest distinguishes unstaged, staged, and untracked state" do
    root = git_repo!()
    on_exit(fn -> File.rm_rf!(root) end)

    clean = PreflightAttestation.capture_state!(root, "gate-a")
    assert clean["clean"]

    File.write!(Path.join(root, "tracked.txt"), "changed\n")
    unstaged = PreflightAttestation.capture_state!(root, "gate-a")
    refute unstaged["clean"]
    refute unstaged["worktree_content_digest"] == clean["worktree_content_digest"]

    git!(root, ["add", "tracked.txt"])
    staged = PreflightAttestation.capture_state!(root, "gate-a")
    refute staged["worktree_content_digest"] == unstaged["worktree_content_digest"]

    File.write!(Path.join(root, "new.txt"), "untracked\n")
    untracked = PreflightAttestation.capture_state!(root, "gate-a")
    refute untracked["worktree_content_digest"] == staged["worktree_content_digest"]
  end

  test "captured toolchain identity includes OTP release and patch version" do
    root = git_repo!()
    on_exit(fn -> File.rm_rf!(root) end)

    captured = PreflightAttestation.capture_state!(root, "gate-a")

    assert captured["schema_version"] == 2
    assert captured["otp_release"] == to_string(:erlang.system_info(:otp_release))
    assert captured["otp_version"] =~ ~r/^\d+\.\d+(?:\.\d+)?(?:[-+].*)?$/
    assert String.starts_with?(captured["otp_version"], captured["otp_release"] <> ".")
  end

  test "write is atomic JSON and invalidation removes only the exact artifact" do
    root = git_repo!()
    evidence = Path.join(root, "evidence/preflight.json")
    on_exit(fn -> File.rm_rf!(root) end)

    artifact =
      PreflightAttestation.write!(
        root,
        "gate-a",
        %{checks: [%{"id" => "docs", "status" => "passed"}], total_wall_ms: 4},
        path: evidence
      )

    assert artifact["status"] == "passed"
    assert Jason.decode!(File.read!(evidence))["head_sha"] == artifact["head_sha"]
    assert Path.wildcard(evidence <> ".tmp-*") == []

    assert :ok = PreflightAttestation.invalidate!(root, path: evidence)
    refute File.exists?(evidence)
    assert File.exists?(Path.join(root, "tracked.txt"))
  end

  defp state do
    %{
      "schema_version" => 2,
      "canonical_repo_root" => "/repo",
      "head_sha" => String.duplicate("a", 40),
      "clean" => true,
      "worktree_content_digest" => String.duplicate("b", 64),
      "mix_lock_digest" => String.duplicate("c", 64),
      "gate_definition_digest" => String.duplicate("d", 64),
      "elixir_version" => "1.19.5",
      "otp_release" => "29",
      "otp_version" => "29.0.1"
    }
  end

  defp git_repo! do
    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-preflight-attestation-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    git!(root, ["init", "--quiet"])
    git!(root, ["config", "user.email", "test@example.invalid"])
    git!(root, ["config", "user.name", "Allbert Test"])
    File.write!(Path.join(root, "tracked.txt"), "initial\n")
    git!(root, ["add", "tracked.txt"])
    git!(root, ["commit", "--quiet", "-m", "initial"])
    root
  end

  defp git!(root, args) do
    assert {output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    output
  end
end
