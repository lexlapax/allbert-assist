defmodule AllbertAssist.Actions.ConfirmationsActionsTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Settings

  setup do
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-confirmation-actions-#{System.unique_integer([:positive])}"
      )

    settings_root = Path.join(root, "settings")
    confirmations_root = Path.join(root, "confirmations")

    Application.put_env(:allbert_assist, Settings, root: settings_root)
    Application.put_env(:allbert_assist, Confirmations, root: confirmations_root)

    on_exit(fn ->
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "list and show confirmations through the action runner" do
    assert {:ok, record} = Confirmations.create(base_attrs())

    assert {:ok, list_response} =
             Runner.run("list_confirmations", %{}, %{actor: "local", channel: :test})

    assert list_response.status == :completed
    assert [listed] = list_response.confirmations
    assert listed["id"] == record["id"]
    assert list_response.runner_metadata.action_name == "list_confirmations"

    assert {:ok, show_response} =
             Runner.run("show_confirmation", %{id: record["id"]}, %{
               actor: "local",
               channel: :test
             })

    assert show_response.status == :completed
    assert show_response.confirmation["id"] == record["id"]
    assert show_response.runner_metadata.permission_decision.permission == :read_only
  end

  test "approve and deny resolve pending records idempotently" do
    assert {:ok, approval_candidate} =
             Confirmations.create(Map.put(base_attrs(), :id, "conf_approve"))

    assert {:ok, approve_response} =
             Runner.run(
               "approve_confirmation",
               %{id: approval_candidate["id"], reason: "looks good"},
               %{actor: "local", channel: :cli, surface: "mix allbert.confirmations"}
             )

    assert approve_response.status == :completed
    assert approve_response.confirmation["status"] == "approved"
    assert approve_response.confirmation["operator_resolution"]["resolver_channel"] == "cli"

    assert {:ok, approve_again} =
             Runner.run("approve_confirmation", %{id: approval_candidate["id"]}, %{
               actor: "local",
               channel: :cli
             })

    assert approve_again.status == :completed
    assert approve_again.actions |> hd() |> get_in([:confirmation_metadata, :idempotent?])

    assert {:ok, denial_candidate} = Confirmations.create(Map.put(base_attrs(), :id, "conf_deny"))

    assert {:ok, deny_response} =
             Runner.run(
               "deny_confirmation",
               %{id: denial_candidate["id"], reason: "not needed"},
               %{actor: "local", channel: :liveview, surface: "/settings"}
             )

    assert deny_response.status == :completed
    assert deny_response.confirmation["status"] == "denied"
    assert deny_response.confirmation["operator_resolution"]["resolver_channel"] == "liveview"
  end

  test "deny requires a reason when configured" do
    assert {:ok, _setting} =
             Settings.put("confirmations.require_reason_for_denial", true, %{audit?: false})

    assert {:ok, record} = Confirmations.create(base_attrs())

    assert {:ok, response} =
             Runner.run("deny_confirmation", %{id: record["id"]}, %{actor: "local", channel: :cli})

    assert response.status == :denied
    assert response.error == :denial_reason_required
    assert {:ok, pending} = Confirmations.read(record["id"])
    assert pending["status"] == "pending"
  end

  test "confirmation decision permission can deny approval" do
    assert {:ok, _setting} =
             Settings.put("permissions.confirmation_decide", "denied", %{audit?: false})

    assert {:ok, record} = Confirmations.create(base_attrs())

    assert {:ok, response} =
             Runner.run("approve_confirmation", %{id: record["id"]}, %{
               actor: "local",
               channel: :cli
             })

    assert response.status == :denied
    assert response.runner_metadata.permission_decision.decision == :denied
    assert {:ok, pending} = Confirmations.read(record["id"])
    assert pending["status"] == "pending"
  end

  test "expire confirmations resolves expired records" do
    assert {:ok, _expired} =
             Confirmations.create(base_attrs(), ttl_minutes: 1, now: ~U[2000-01-01 00:00:00Z])

    assert {:ok, response} =
             Runner.run("expire_confirmations", %{}, %{actor: "local", channel: :cli})

    assert response.status == :completed
    assert [resolved] = response.confirmations
    assert resolved["status"] == "expired"
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
