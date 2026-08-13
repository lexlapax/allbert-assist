defmodule AllbertAssist.Actions.Mcp.ScanActionsTest do
  alias AllbertAssist.TestSupport.ReadyEffectContext

  @moduledoc """
  v0.62 M8.19: MCP discovery scan lifecycle commands run on-spine through Runner.
  """
  use AllbertAssist.DataCase, async: false, lane: :external_runtime_serial

  import AllbertAssist.TestSupport.ActionEnvelopeAssertions

  alias AllbertAssist.Actions.Mcp.ScanEnable
  alias AllbertAssist.Actions.Mcp.ScanPause
  alias AllbertAssist.Actions.Mcp.ScanResume
  alias AllbertAssist.Actions.Mcp.ScanRunOnce
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Jobs
  alias AllbertAssist.McpRegistryFixtures
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-mcp-scan-actions-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))

    on_exit(fn ->
      restore_env(Paths, original_paths)
      restore_env(Settings, original_settings)
      File.rm_rf!(home)
    end)

    :ok
  end

  test "enable, pause, and resume mutate the managed scan job through registered actions" do
    ctx = ctx("operator")

    assert {:ok, enable} = Runner.run("mcp_scan_enable", %{user_id: "alice"}, ctx)
    assert enable.status == :completed
    assert enable.permission_decision.permission == :settings_write
    assert enable.scan_job.user_id == "alice"
    assert enable.scan_job.status == "paused"
    assert action_name(enable) == "mcp_scan_enable"

    assert_mcp_envelope(enable,
      name: "mcp_scan_enable",
      message: "MCP discovery scan enabled.",
      status: :completed,
      action_status: :completed,
      permission: :settings_write,
      decision: :allowed,
      extra_keys: [:scan_job],
      metadata: %{
        command: "enable",
        user_id: "alice",
        job_id: enable.scan_job.id,
        error: nil
      }
    )

    assert [%{name: "mcp-discovery-scan", user_id: "alice", status: "paused"}] =
             Jobs.list_jobs("alice")

    assert {:ok, resume} = Runner.run("mcp_scan_resume", %{user_id: "alice"}, ctx)
    assert resume.status == :completed
    assert resume.permission_decision.permission == :job_write
    assert resume.scan_job.status == "active"
    assert action_name(resume) == "mcp_scan_resume"

    assert_mcp_envelope(resume,
      name: "mcp_scan_resume",
      message: "MCP discovery scan resumed.",
      status: :completed,
      action_status: :completed,
      permission: :job_write,
      decision: :allowed,
      extra_keys: [:scan_job],
      metadata: %{
        command: "resume",
        user_id: "alice",
        job_id: resume.scan_job.id,
        error: nil
      }
    )

    assert {:ok, pause} = Runner.run("mcp_scan_pause", %{user_id: "alice"}, ctx)
    assert pause.status == :completed
    assert pause.permission_decision.permission == :job_write
    assert pause.scan_job.status == "paused"
    assert action_name(pause) == "mcp_scan_pause"

    assert_mcp_envelope(pause,
      name: "mcp_scan_pause",
      message: "MCP discovery scan paused.",
      status: :completed,
      action_status: :completed,
      permission: :job_write,
      decision: :allowed,
      extra_keys: [:scan_job],
      metadata: %{
        command: "pause",
        user_id: "alice",
        job_id: pause.scan_job.id,
        error: nil
      }
    )
  end

  test "run-once success preserves the exact scan result envelope" do
    configure_external!()
    stub_registry()

    action_context =
      ctx("local")
      |> Map.put(:mcp, %{req_plug: {Req.Test, __MODULE__}})

    assert {:ok, _enabled} =
             Runner.run("mcp_scan_enable", %{user_id: "local"}, action_context)

    assert {:ok, response} =
             Runner.run(
               "mcp_scan_run_once",
               %{query: "weather", user_id: "local"},
               action_context
             )

    assert response.scan_run.run.status == "completed"
    assert response.scan_run.response.status == :completed

    assert_mcp_envelope(response,
      name: "mcp_scan_run_once",
      message: "MCP discovery scan ran once.",
      status: :completed,
      action_status: :completed,
      permission: :job_write,
      decision: :allowed,
      extra_keys: [:scan_run],
      metadata: %{
        command: "run-once",
        user_id: "local",
        job_id: response.scan_run.job.id,
        run_id: response.scan_run.run.id,
        error: nil
      }
    )
  end

  test "all four actions preserve exact denial envelopes and permission metadata" do
    for {module, action_name, permission, command, params} <- [
          {ScanEnable, "mcp_scan_enable", :settings_write, "enable", %{user_id: "alice"}},
          {ScanPause, "mcp_scan_pause", :job_write, "pause", %{user_id: "alice"}},
          {ScanResume, "mcp_scan_resume", :job_write, "resume", %{user_id: "alice"}},
          {ScanRunOnce, "mcp_scan_run_once", :job_write, "run-once",
           %{user_id: "alice", query: "weather"}}
        ] do
      assert {:ok, response} =
               module.run(params, %{selected_action: "unregistered_boundary_probe"})

      metadata = %{
        command: command,
        user_id: "alice",
        job_id: nil,
        error: :permission_denied
      }

      metadata =
        if command == "run-once", do: Map.put(metadata, :run_id, nil), else: metadata

      assert_mcp_callback_denial(response,
        name: action_name,
        permission: permission,
        metadata: metadata
      )
    end
  end

  test "resume and run-once preserve exact operational-failure envelopes while disabled" do
    for {action_name, command, message, params} <- [
          {"mcp_scan_resume", "resume", "MCP discovery scan resume failed: :discovery_disabled",
           %{user_id: "local"}},
          {"mcp_scan_run_once", "run-once",
           "MCP discovery scan run-once failed: :discovery_disabled",
           %{user_id: "local", query: "weather"}}
        ] do
      assert {:ok, response} = Runner.run(action_name, params, ctx("local"))
      assert response.error == :discovery_disabled

      assert_mcp_envelope(response,
        name: action_name,
        message: message,
        status: :failed,
        action_status: :failed,
        permission: :job_write,
        decision: :allowed,
        extra_keys: [:error],
        metadata:
          %{
            command: command,
            user_id: "local",
            job_id: nil,
            run_id: if(command == "run-once", do: nil, else: :not_present),
            error: :discovery_disabled
          }
          |> drop_not_present()
      )
    end
  end

  defp action_name(%{actions: [action]}), do: action.name

  defp configure_external! do
    assert {:ok, _setting} = put_setting("external_services.enabled", true)

    assert {:ok, _setting} =
             put_setting("external_services.allowed_hosts", ["registry.modelcontextprotocol.io"])

    assert {:ok, _setting} =
             put_setting("external_services.allowed_paths", ["/v0.1/servers"])

    assert {:ok, _setting} = put_setting("external_services.allowed_methods", ["GET"])
  end

  defp put_setting(key, value) do
    Settings.put(
      key,
      value,
      ReadyEffectContext.attach(%{audit?: false})
    )
  end

  defp stub_registry do
    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{
          "servers" => [McpRegistryFixtures.official_weather_server()],
          "metadata" => %{}
        })
      )
    end)
  end

  defp drop_not_present(metadata) do
    Map.reject(metadata, fn {_key, value} -> value == :not_present end)
  end

  defp ctx(user_id), do: %{actor: user_id, user_id: user_id, channel: :cli}

  defp restore_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_env(key, value), do: Application.put_env(:allbert_assist, key, value)
end
