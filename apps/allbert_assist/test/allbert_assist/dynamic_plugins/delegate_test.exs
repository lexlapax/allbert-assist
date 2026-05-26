defmodule AllbertAssist.DynamicPlugins.DelegateTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Confirmations
  alias AllbertAssist.DynamicPlugins.Delegate
  alias AllbertAssist.Memory
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_memory_config = Application.get_env(:allbert_assist, Memory)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-dynamic-delegate-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Memory, root: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Memory, original_memory_config)
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "fails closed when a reviewed facade is not operator-enabled" do
    assert {:error, {:dynamic_delegate_facade_not_enabled, "append_memory"}} =
             Delegate.run("append_memory", %{memory: "remember this"}, cli_context())
  end

  test "runs allowlisted append_memory through the action runner" do
    allow_facades!(["append_memory"])

    assert {:ok, response} =
             Delegate.run(
               "append_memory",
               %{memory: "Prefer short release notes.", source_text: "remember preference"},
               cli_context()
             )

    assert response.status == :completed
    assert [%{name: "append_memory", permission: :memory_write, durable: true}] = response.actions
    assert response.runner_metadata.action_name == "append_memory"
  end

  test "runs allowlisted external_network_request through normal confirmation creation" do
    allow_facades!(["external_network_request"])
    configure_external()

    assert {:ok, response} =
             Delegate.run(
               "external_network_request",
               %{url: "https://example.com/status"},
               cli_context()
             )

    assert response.status == :needs_confirmation
    assert response.confirmation_id =~ "conf_"
    assert [%{name: "external_network_request", permission: :external_network}] = response.actions

    assert {:ok, pending} = Confirmations.read(response.confirmation_id)
    assert pending["target_action"]["name"] == "external_network_request"
    assert pending["target_permission"] == "external_network"
  end

  test "denies unsupported or protected facade names regardless of settings" do
    allow_facades!(["append_memory"])

    assert {:error, {:dynamic_delegate_facade_not_supported, "run_shell_command"}} =
             Delegate.run("run_shell_command", %{command: "echo no"}, cli_context())
  end

  defp allow_facades!(facades) do
    assert {:ok, _setting} =
             Settings.put("dynamic_codegen.allowed_facades", facades, %{audit?: false})
  end

  defp configure_external do
    assert {:ok, _setting} = Settings.put("external_services.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_hosts", ["example.com"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_paths", ["/status"], %{audit?: false})
  end

  defp cli_context do
    %{
      actor: "local",
      channel: :cli,
      surface: "cli",
      request: %{operator_id: "local", channel: "cli", input_signal_id: "sig_test"}
    }
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
