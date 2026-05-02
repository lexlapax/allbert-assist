defmodule Mix.Tasks.Allbert.ConfirmationsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Settings
  alias Mix.Tasks.Allbert.Confirmations, as: ConfirmationsTask

  setup do
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-confirmations-task-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Settings, original_settings_config)
      Mix.Task.reenable("allbert.confirmations")
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "lists, shows, denies, and lists resolved confirmations" do
    assert {:ok, record} = Confirmations.create(base_attrs())

    list_output = capture_io(fn -> assert :ok = ConfirmationsTask.run(["list"]) end)
    assert list_output =~ record["id"]
    assert list_output =~ "status=pending"
    assert list_output =~ "origin=local/cli"

    show_output = capture_io(fn -> assert :ok = ConfirmationsTask.run(["show", record["id"]]) end)
    assert show_output =~ "Requested:"
    assert show_output =~ "Resolver: none/none"

    deny_output =
      capture_io(fn ->
        assert :ok =
                 ConfirmationsTask.run(["deny", record["id"], "--reason", "not", "needed"])
      end)

    assert deny_output =~ "status=denied"
    assert deny_output =~ "Resolver: local/cli"

    resolved_output =
      capture_io(fn -> assert :ok = ConfirmationsTask.run(["list", "--resolved"]) end)

    assert resolved_output =~ record["id"]
    assert resolved_output =~ "status=denied"
  end

  test "approve and expire commands render operator output" do
    assert {:ok, approval} = Confirmations.create(Map.put(base_attrs(), :id, "conf_cli_approve"))

    approve_output =
      capture_io(fn ->
        assert :ok = ConfirmationsTask.run(["approve", approval["id"], "--reason", "ok"])
      end)

    assert approve_output =~ "conf_cli_approve status=adapter_unavailable"

    expire_output = capture_io(fn -> assert :ok = ConfirmationsTask.run(["expire"]) end)
    assert expire_output =~ "Expired: 0"
  end

  test "missing confirmation raises a Mix error" do
    assert_raise Mix.Error, ~r/confirmation_not_found/, fn ->
      ConfirmationsTask.run(["show", "missing"])
    end
  end

  defp base_attrs do
    %{
      origin: %{actor: "local", channel: :cli, surface: "mix allbert.ask"},
      target_action: %{name: "external_network_request"},
      target_permission: :external_network,
      target_execution_mode: :external_network_unavailable,
      security_decision: %{permission: :external_network, decision: :needs_confirmation},
      params_summary: %{url: "https://example.com"}
    }
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
