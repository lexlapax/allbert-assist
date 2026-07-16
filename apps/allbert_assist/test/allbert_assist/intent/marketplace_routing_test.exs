defmodule AllbertAssist.Intent.MarketplaceRoutingTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Agents.IntentAgent
  alias AllbertAssist.Paths

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_home = System.get_env("ALLBERT_HOME")
    home = temp_path("home")

    System.put_env("ALLBERT_HOME", home)
    Application.put_env(:allbert_assist, Paths, home: home)

    on_exit(fn ->
      restore_app_env(Paths, original_paths_config)
      restore_env("ALLBERT_HOME", original_home)
      File.rm_rf!(home)
    end)

    :ok
  end

  test "routes Marketplace Lite phrase corpus through IntentAgent" do
    assert {:ok, response} = respond("show me the reviewed skill catalog")
    assert response.status == :completed
    assert response.decision.selected_action == "list_marketplace_entries"
    assert [%{"kind" => "skill"}] = Enum.map(response.result.entries, &Map.take(&1, ["kind"]))

    assert {:ok, response} = respond("show me reviewed templates")
    assert response.status == :completed
    assert response.decision.selected_action == "list_marketplace_entries"
    assert [%{"kind" => "template"}] = Enum.map(response.result.entries, &Map.take(&1, ["kind"]))

    assert {:ok, response} = respond("what's in the marketplace")
    assert response.status == :completed
    assert response.decision.selected_action == "list_marketplace_entries"
    assert length(response.result.entries) == 3

    assert {:ok, response} = respond("install the allbert/research-helpers skill")
    assert response.status == :completed
    assert response.decision.selected_action == "install_marketplace_bundle"
    assert response.result.installed["install_state"] == "disabled_untrusted"

    assert {:ok, response} = respond("show me installed marketplace skills")
    assert response.status == :completed
    assert response.decision.selected_action == "list_installed_marketplace_bundles"

    assert [%{"entry_id" => "allbert/research-helpers"}] =
             Enum.map(response.result.installed, &Map.take(&1, ["entry_id"]))

    assert {:ok, response} = respond("verify allbert/research-helpers")
    assert response.status == :completed
    assert response.decision.selected_action == "verify_marketplace_bundle_hash"
    assert response.result.status == :ok

    assert {:ok, response} = respond("rollback allbert/research-helpers")
    assert response.status == :completed
    assert response.decision.selected_action == "rollback_marketplace_install"
    assert response.result.removed["entry_id"] == "allbert/research-helpers"
  end

  defp respond(text) do
    IntentAgent.respond(%{
      text: text,
      channel: :test,
      user_id: "local",
      operator_id: "local",
      input_signal_id: "sig-marketplace-#{System.unique_integer([:positive])}"
    })
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-marketplace-routing-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
