defmodule AllbertAssist.Tools.DiscoveryScanTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Jobs
  alias AllbertAssist.McpRegistryFixtures
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Tools.Discovery
  alias AllbertAssist.Tools.Discovery.Scan

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-discovery-scan-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "enable creates a paused registered-action scan job and resume schedules it" do
    assert {:ok, job} = Scan.enable()
    assert job.status == "paused"
    assert job.name == "mcp-discovery-scan"
    assert job.target_type == "registered_action"
    assert get_in(job.target, ["action_name"]) == "find_mcp_tools"
    assert {:ok, true} = Settings.get("mcp.discovery.enabled")

    assert {:ok, _setting} =
             Settings.put("mcp.discovery.scan.schedule", "daily", %{audit?: false})

    assert {:ok, resumed} = Scan.resume()
    assert resumed.status == "active"
    assert resumed.schedule == %{"kind" => "daily", "at" => "09:00"}
    assert %DateTime{} = resumed.next_due_at
  end

  test "run_once records pending suggestions without activating the paused job" do
    configure_external()
    stub_registry()

    assert {:ok, _job} = Scan.enable()

    assert {:ok, %{job: job, run: run, response: response}} =
             Scan.run_once("weather",
               action_context: %{mcp: %{req_plug: {Req.Test, __MODULE__}}}
             )

    assert job.status == "paused"
    assert run.status == "completed"
    assert response.status == :completed
    assert [_suggestion] = Discovery.list_suggestions(status: "pending")

    assert [%{name: "mcp-discovery-scan", status: "paused"}] = Jobs.list_jobs("local")
  end

  test "resume and run_once fail closed while discovery is disabled" do
    assert {:error, :discovery_disabled} = Scan.resume()
    assert {:error, :discovery_disabled} = Scan.run_once("weather")
  end

  defp configure_external do
    assert {:ok, _setting} = Settings.put("external_services.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put(
               "external_services.allowed_hosts",
               ["registry.modelcontextprotocol.io"],
               %{audit?: false}
             )

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_paths", ["/v0.1/servers"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_methods", ["GET"], %{audit?: false})
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

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
