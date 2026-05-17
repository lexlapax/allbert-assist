defmodule AllbertAssist.JidoBackedTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Confirmations.Store
  alias AllbertAssist.Confirmations.Store.Agent, as: StoreAgent
  alias AllbertAssist.JidoBacked
  alias AllbertAssist.Settings

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-jido-backed-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "debug trace setting is default off and writable" do
    assert {:ok, false} = Settings.get("allbert.jido.debug_trace")
    refute JidoBacked.debug_trace_enabled?()

    assert {:ok, resolved} =
             Settings.put("allbert.jido.debug_trace", true, %{audit?: false})

    assert resolved.value == true
    assert JidoBacked.debug_trace_enabled?()
  end

  test "private confirmation command modules are not registered capability actions" do
    for module <- StoreAgent.command_modules() do
      refute Registry.registered_module?(module)
      assert {:error, {:unknown_action, ^module}} = Registry.capability(module)
    end
  end

  test "dispatch through a JidoBacked agent unwraps command results" do
    assert {:ok, record} =
             Store.create(%{
               origin: %{actor: "local", channel: :test},
               target_action: %{name: "direct_answer"},
               target_permission: :read_only,
               target_execution_mode: :read_only,
               security_decision: %{permission: :read_only, decision: :allowed},
               params_summary: %{message: "hello"}
             })

    assert {:ok, ^record} =
             JidoBacked.dispatch(
               StoreAgent,
               "allbert.confirmations.store.read",
               %{id: record["id"]},
               source: "/test"
             )
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
