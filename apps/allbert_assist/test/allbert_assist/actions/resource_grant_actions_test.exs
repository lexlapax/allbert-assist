defmodule AllbertAssist.Actions.ResourceGrantActionsTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Resources.Grants
  alias AllbertAssist.Resources.Scope
  alias AllbertAssist.Settings

  setup do
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-resource-grant-actions-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "list, show, and revoke remembered grants through registered actions" do
    assert {:ok, grant} =
             Grants.remember(external_ref("https://example.com/status"),
               id: "grant_action_smoke",
               reason: "action smoke",
               audit?: false
             )

    assert {:ok, list_response} =
             Runner.run("list_resource_grants", %{}, %{actor: "local", channel: :test})

    assert list_response.status == :completed
    assert Enum.any?(list_response.grants, &(&1["id"] == grant["id"]))
    assert list_response.actions |> hd() |> get_in([:resource_grants, :count]) == 1

    assert {:ok, show_response} =
             Runner.run("show_resource_grant", %{id: grant["id"]}, %{
               actor: "local",
               channel: :test
             })

    assert show_response.status == :completed
    assert show_response.grant["id"] == grant["id"]
    assert show_response.grant["operation_class"] == "external_service_request"

    assert {:ok, revoke_response} =
             Runner.run("revoke_resource_grant", %{id: grant["id"], reason: "done"}, %{
               actor: "local",
               channel: :cli
             })

    assert revoke_response.status == :completed
    assert revoke_response.grant["revoked_at"]

    assert {:error, {:grant_revoked, "grant_action_smoke"}} =
             Grants.find_applicable(external_ref("https://example.com/status"),
               permission: :external_network
             )
  end

  test "remember_resource_grant records approval memory from confirmation resource refs" do
    assert {:ok, confirmation} =
             Confirmations.create(%{
               id: "conf_remember_action",
               origin: %{actor: "local", channel: :cli, surface: "mix allbert.external"},
               target_action: %{name: "external_network_request"},
               target_permission: :external_network,
               target_execution_mode: :req_http,
               security_decision: %{permission: :external_network, decision: :needs_confirmation},
               params_summary: %{
                 url: "https://example.com/status",
                 resource_refs: [external_ref("https://example.com/status")]
               }
             })

    assert {:ok, remember_response} =
             Runner.run(
               "remember_resource_grant",
               %{id: confirmation["id"], remember_scope: "exact", reason: "remember exact"},
               %{actor: "local", channel: :cli, surface: "mix allbert.resources"}
             )

    assert remember_response.status == :completed
    assert [grant] = remember_response.grants
    assert grant["operation_class"] == "external_service_request"
    assert grant["metadata"]["confirmation_id"] == confirmation["id"]
    assert grant["resolver_channel"] == "cli"
  end

  defp external_ref(url) do
    %{
      origin_kind: :remote_url,
      canonical_id: url,
      operation_class: :external_service_request,
      access_mode: :fetch,
      scope: Scope.to_map(Scope.exact_url(url)),
      downstream_consumer: :req_http
    }
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
