defmodule Mix.Tasks.Allbert.ResourcesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Resources.Grants
  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Resources.Scope
  alias AllbertAssist.Settings
  alias Mix.Tasks.Allbert.Resources, as: ResourcesTask

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-resources-task-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      Mix.Task.reenable("allbert.resources")
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "lists, shows, and revokes remembered resource grants" do
    assert {:ok, grant} =
             Grants.remember(external_ref("https://example.com/status"),
               id: "grant_mix_resource",
               reason: "mix task smoke",
               audit?: false
             )

    list_output = capture_io(fn -> assert :ok = ResourcesTask.run(["grants", "list"]) end)
    assert list_output =~ "grant_mix_resource status=active"
    assert list_output =~ "external_service_request"
    assert list_output =~ "resource_uri=https://example.com/status"
    assert list_output =~ "exact_url:https://example.com/status"

    show_output =
      capture_io(fn -> assert :ok = ResourcesTask.run(["grants", "show", grant["id"]]) end)

    assert show_output =~ "Reason: mix task smoke"
    assert show_output =~ "Expires: none"

    revoke_output =
      capture_io(fn ->
        assert :ok =
                 ResourcesTask.run([
                   "grants",
                   "revoke",
                   grant["id"],
                   "--reason",
                   "no longer needed"
                 ])
      end)

    assert revoke_output =~ "grant_mix_resource status=revoked"

    list_after_revoke = capture_io(fn -> assert :ok = ResourcesTask.run(["grants", "list"]) end)
    assert list_after_revoke =~ "grant_mix_resource status=revoked"
  end

  defp external_ref(url) do
    %{
      resource_uri: ResourceURI.url!(url),
      origin_kind: :remote_url,
      canonical_id: url,
      operation_class: :external_service_request,
      access_mode: :fetch,
      scope: Scope.exact_url(url),
      downstream_consumer: :req_http
    }
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
