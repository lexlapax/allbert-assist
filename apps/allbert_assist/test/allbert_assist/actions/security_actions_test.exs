defmodule AllbertAssist.Actions.SecurityActionsTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Actions.Security.Status
  alias AllbertAssist.Settings

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-security-actions-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Settings, root: root)

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "security status action returns redacted effective status" do
    assert {:ok, response} = Status.run(%{}, %{actor: "local", channel: :test})

    assert response.status == :completed
    assert response.permission_decision.decision == :allowed

    assert Enum.any?(
             response.security_status.permission_defaults,
             &(&1.permission == :command_execute)
           )

    assert Enum.any?(response.security_status.safety_floors, &(&1.permission == :unknown))
    assert response.security_status.capability_boundaries.external_services.enabled == false

    assert response.security_status.capability_boundaries.package_installs.allowed_managers == [
             "npm"
           ]

    refute inspect(response) =~ "secret://"
  end

  test "security status is invokable through the runner" do
    assert {:ok, response} =
             Runner.run("security_status", %{}, %{
               request: %{operator_id: "local", channel: :test}
             })

    assert response.status == :completed
    assert response.runner_metadata.action_name == "security_status"
    assert response.runner_metadata.permission_decision.context.action.name == "security_status"
    assert response.runner_metadata.permission_decision.context.action.registered?
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
