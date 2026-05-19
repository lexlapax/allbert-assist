defmodule AllbertAssist.Workspace.Fragment.SigningSecretTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias AllbertAssist.Paths
  alias AllbertAssist.Workspace.Fragment.SigningSecret

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)

    home =
      Path.join(System.tmp_dir!(), "allbert-signing-secret-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: home)

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  test "bootstraps a durable 32-byte hex signing secret", %{home: home} do
    secret = SigningSecret.ensure!()

    assert SigningSecret.valid?(secret)
    assert byte_size(secret) == 64
    assert secret == SigningSecret.ensure!()

    path = Path.join([home, "workspace", "secrets", "signing_secret"])
    assert SigningSecret.path() == path
    assert File.read!(path) == secret <> "\n"
    assert (File.stat!(path).mode &&& 0o777) == 0o600
  end

  test "rotates the secret without exposing raw key material in metadata" do
    old_secret = SigningSecret.ensure!()

    result = SigningSecret.rotate!()

    assert %{
             fingerprint: fingerprint,
             path: path,
             previous_fingerprint: previous_fingerprint,
             previous_expires_at: %DateTime{} = previous_expires_at,
             overlap_seconds: 60,
             rotated_at: %DateTime{}
           } = result

    assert path == SigningSecret.path()
    assert byte_size(fingerprint) == 12
    assert byte_size(previous_fingerprint) == 12
    assert DateTime.compare(previous_expires_at, DateTime.utc_now()) == :gt

    {:ok, new_secret} = SigningSecret.read()
    assert SigningSecret.valid?(new_secret)
    refute new_secret == old_secret
    refute inspect(result) =~ new_secret
    refute inspect(result) =~ old_secret

    assert {:ok, verification_secrets} = SigningSecret.verification_secrets()
    assert verification_secrets == [new_secret, old_secret]
    assert File.exists?(SigningSecret.previous_path())
    assert (File.stat!(SigningSecret.previous_path()).mode &&& 0o777) == 0o600
  end

  test "expired previous secrets are ignored and cleaned up" do
    old_secret = SigningSecret.ensure!()
    new_secret = String.duplicate("a", 64)
    File.write!(SigningSecret.path(), new_secret <> "\n")

    File.write!(
      SigningSecret.previous_path(),
      Jason.encode!(%{
        "secret" => old_secret,
        "expires_at" => DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_iso8601()
      })
    )

    assert {:ok, [^new_secret]} = SigningSecret.verification_secrets()
    refute File.exists?(SigningSecret.previous_path())
  end

  test "rejects malformed existing secret files" do
    path = SigningSecret.path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "not-a-secret\n")

    assert_raise RuntimeError, ~r/not a 32-byte/, fn ->
      SigningSecret.ensure!()
    end
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
