defmodule AllbertAssist.Actions.ExternalNetworkRequestTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.ResourceMetadata
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-external-action-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    configure_external()

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "creates a pending confirmation before any HTTP call" do
    assert {:ok, response} =
             Runner.run("external_network_request", %{url: "https://example.com/status"}, %{
               actor: "local",
               channel: :test
             })

    assert response.status == :needs_confirmation
    assert response.message =~ "Nothing has executed yet"
    assert response.confirmation["target_execution_mode"] == "req_http"
    assert response.confirmation["params_summary"]["url"] == "https://example.com/status"

    assert [
             %{
               execution: :pending_confirmation,
               permission_decision: %{decision: :needs_confirmation},
               confirmation_id: confirmation_id
             }
           ] = response.actions

    assert {:ok, pending} = Confirmations.read(confirmation_id)
    assert pending["status"] == "pending"
  end

  test "resource refs keep canonical URL separate from redacted display URL" do
    assert {:ok, response} =
             Runner.run(
               "external_network_request",
               %{url: "https://example.com/status?token=secret"},
               %{actor: "local", channel: :test}
             )

    summary = response.confirmation["params_summary"]
    assert summary["canonical_url"] == "https://example.com/status?token=secret"
    assert summary["display_url"] == "https://example.com/status?[REDACTED]"
    assert summary["url"] == "https://example.com/status?[REDACTED]"

    assert [ref] = summary["resource_refs"]
    assert ref["canonical_id"] == "https://example.com/status?token=secret"

    assert ref["scope"] == %{
             "kind" => "exact_url",
             "value" => "https://example.com/status?token=secret"
           }

    assert ref["metadata"]["display_url"] == "https://example.com/status?[REDACTED]"

    assert ResourceMetadata.lines(response.confirmation) == [
             "Resource remote_url external_service_request fetch exact_url:https://example.com/status?[REDACTED] consumer=req_http"
           ]
  end

  test "approval resumes the confirmed Req adapter" do
    Req.Test.expect(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    assert {:ok, response} =
             Runner.run("external_network_request", %{url: "https://example.com/status"}, %{
               actor: "local",
               channel: :cli
             })

    assert {:ok, approved} =
             Runner.run(
               "approve_confirmation",
               %{id: response.confirmation_id, reason: "M2 smoke"},
               %{
                 actor: "local",
                 channel: :cli,
                 external: %{req_plug: {Req.Test, __MODULE__}}
               }
             )

    assert approved.status == :completed
    assert approved.confirmation["status"] == "approved"
    assert approved.confirmation["operator_resolution"]["target_resumed?"]
    assert approved.confirmation["operator_resolution"]["target_status"] == "completed"
    assert approved.confirmation["operator_resolution"]["target_result"]["http_status"] == 200
  end

  test "approved summarize_url fetch reports missing summarizer without changing operation scope" do
    Req.Test.expect(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 200, "report body")
    end)

    params = %{
      url: "https://example.com/status",
      operation_class: "summarize_url",
      downstream_consumer: "url_summarizer",
      postprocess: "summarize_url"
    }

    assert {:ok, response} =
             Runner.run("external_network_request", params, %{
               actor: "local",
               channel: :cli
             })

    assert response.status == :needs_confirmation
    assert response.message =~ "Operation: summarize_url"
    assert response.confirmation["params_summary"]["operation_class"] == "summarize_url"

    assert [ref] = response.confirmation["params_summary"]["resource_refs"]
    assert ref["operation_class"] == "summarize_url"
    assert ref["access_mode"] == "summarize"
    assert ref["downstream_consumer"] == "url_summarizer"

    assert {:ok, approved} =
             Runner.run(
               "approve_confirmation",
               %{id: response.confirmation_id, reason: "M4 summary smoke"},
               %{
                 actor: "local",
                 channel: :cli,
                 external: %{req_plug: {Req.Test, __MODULE__}}
               }
             )

    target_result = approved.confirmation["operator_resolution"]["target_result"]

    assert approved.confirmation["operator_resolution"]["target_status"] == "completed"
    assert target_result["http_status"] == 200
    assert target_result["request"]["operation_class"] == "summarize_url"
    assert target_result["postprocess"]["status"] == "unavailable"
    assert target_result["postprocess"]["reason"] == "summarizer_unavailable"
  end

  test "approval can remember an exact URL grant and later skip confirmation" do
    Req.Test.expect(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 200, "first")
    end)

    assert {:ok, response} =
             Runner.run("external_network_request", %{url: "https://example.com/status"}, %{
               actor: "local",
               channel: :cli
             })

    assert {:ok, approved} =
             Runner.run(
               "approve_confirmation",
               %{
                 id: response.confirmation_id,
                 reason: "remember exact URL",
                 remember_scope: "exact"
               },
               %{
                 actor: "local",
                 channel: :cli,
                 external: %{req_plug: {Req.Test, __MODULE__}}
               }
             )

    assert approved.confirmation["status"] == "approved"
    assert [remembered] = approved.confirmation["operator_resolution"]["remembered_grants"]
    assert remembered["operation_class"] == "external_service_request"
    assert remembered["scope"]["kind"] == "exact_url"

    Req.Test.expect(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 200, "second")
    end)

    assert {:ok, reused} =
             Runner.run("external_network_request", %{url: "https://example.com/status"}, %{
               actor: "local",
               channel: :cli,
               external: %{req_plug: {Req.Test, __MODULE__}}
             })

    assert reused.status == :completed
    assert reused.result.body_preview == "second"
    assert reused.actions |> hd() |> get_in([:resource_grants, :applied?])
    assert reused.actions |> hd() |> get_in([:target_resumed?]) == false
    assert Confirmations.list(status: :pending) == []
  end

  test "summarize_url grant does not authorize generic external service request" do
    Req.Test.expect(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 200, "summary grant")
    end)

    assert {:ok, response} =
             Runner.run(
               "external_network_request",
               %{url: "https://example.com/status", operation_class: "summarize_url"},
               %{actor: "local", channel: :cli}
             )

    assert {:ok, approved} =
             Runner.run(
               "approve_confirmation",
               %{
                 id: response.confirmation_id,
                 reason: "remember summary only",
                 remember_scope: "exact"
               },
               %{
                 actor: "local",
                 channel: :cli,
                 external: %{req_plug: {Req.Test, __MODULE__}}
               }
             )

    assert [remembered] = approved.confirmation["operator_resolution"]["remembered_grants"]
    assert remembered["operation_class"] == "summarize_url"

    assert {:ok, generic} =
             Runner.run(
               "external_network_request",
               %{url: "https://example.com/status"},
               %{
                 actor: "local",
                 channel: :cli,
                 external: %{req_plug: {Req.Test, __MODULE__}}
               }
             )

    assert generic.status == :needs_confirmation

    assert generic.confirmation["params_summary"]["resource_refs"]
           |> hd()
           |> Map.get("operation_class") ==
             "external_service_request"
  end

  test "approval re-check denies policy drift before HTTP execution" do
    assert {:ok, response} =
             Runner.run("external_network_request", %{url: "https://example.com/status"}, %{
               actor: "local",
               channel: :cli
             })

    assert {:ok, _setting} = Settings.put("external_services.enabled", false, %{audit?: false})

    assert {:ok, denied} =
             Runner.run(
               "approve_confirmation",
               %{id: response.confirmation_id, reason: "changed policy"},
               %{actor: "local", channel: :cli, external: %{req_plug: {Req.Test, __MODULE__}}}
             )

    assert denied.status == :completed
    assert denied.confirmation["status"] == "denied"
    assert denied.confirmation["operator_resolution"]["target_resumed?"] == false
    assert denied.confirmation["operator_resolution"]["target_result"]["status"] == "denied"
  end

  defp configure_external do
    assert {:ok, _setting} = Settings.put("external_services.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_hosts", ["example.com"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_paths", ["/status"], %{audit?: false})
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
