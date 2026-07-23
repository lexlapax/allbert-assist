defmodule Mix.Tasks.Allbert.HexAuditTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias Mix.Tasks.Allbert.HexAudit

  setup do
    original_version = Application.get_env(:allbert_assist, :hex_version_provider)
    original_runner = Application.get_env(:allbert_assist, :hex_audit_runner)

    on_exit(fn ->
      restore(:hex_version_provider, original_version)
      restore(:hex_audit_runner, original_runner)
      Mix.Task.reenable("allbert.hex_audit")
    end)

    :ok
  end

  test "rejects missing and pre-2.5 Hex before auditing" do
    for version <- [nil, "2.4.1"] do
      parent = self()
      Application.put_env(:allbert_assist, :hex_version_provider, fn -> version end)
      Application.put_env(:allbert_assist, :hex_audit_runner, fn _ -> send(parent, :audited) end)
      Mix.Task.reenable("allbert.hex_audit")

      assert_raise Mix.Error, ~r/Hex 2\.5\.0 or newer is required/, fn ->
        HexAudit.run([])
      end

      refute_received :audited
    end
  end

  test "delegates to Hex audit on the minimum and newer versions" do
    parent = self()

    for version <- ["2.5.0", "2.5.1", "3.0.0"] do
      Application.put_env(:allbert_assist, :hex_version_provider, fn -> version end)

      Application.put_env(:allbert_assist, :hex_audit_runner, fn args ->
        send(parent, {:audited, version, args})
        :ok
      end)

      Mix.Task.reenable("allbert.hex_audit")
      assert :ok = HexAudit.run(["--format", "human"])
      assert_received {:audited, ^version, ["--format", "human"]}
    end
  end

  test "does not swallow a failing advisory audit" do
    Application.put_env(:allbert_assist, :hex_version_provider, fn -> "2.5.1" end)

    Application.put_env(:allbert_assist, :hex_audit_runner, fn _args ->
      raise Mix.Error, message: "advisory audit failed"
    end)

    assert_raise Mix.Error, "advisory audit failed", fn -> HexAudit.run([]) end
  end

  defp restore(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore(key, value), do: Application.put_env(:allbert_assist, key, value)
end
