defmodule AllbertAssist.Actions.BrowserM4Test do
  use AllbertAssist.DataCase, async: false
  @moduletag :home_fs_serial

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Confirmations.ResourceMetadata
  alias AllbertAssist.Intent.Engine
  alias AllbertAssist.Intent.EvalFixtures
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Security.Redactor

  setup do
    PluginRegistry.clear()
    AppRegistry.clear()

    assert {:ok, "allbert.browser"} = PluginRegistry.register_module(AllbertBrowser.Plugin)
    assert {:ok, :allbert_browser} = AppRegistry.register(AllbertBrowser.App)

    on_exit(fn ->
      PluginRegistry.clear()
      restore_default_plugins()
      AppRegistry.clear()
      restore_default_apps()
    end)

    :ok
  end

  test "redactor removes browser credential surfaces from strings and maps" do
    assert Redactor.redact(%{cookie: "sid=raw", authorization: "Bearer raw"}) == %{
             cookie: "[REDACTED]",
             authorization: "[REDACTED]"
           }

    assert Redactor.redact("Authorization: Bearer raw-token") ==
             "Authorization: Bearer [REDACTED]"

    assert Redactor.redact("Cookie: session=raw; theme=light") == "Cookie: [REDACTED]"

    redacted =
      Redactor.redact("https://user:pass@example.com/path?token=raw&ok=1&session=abc")

    assert redacted ==
             "https://[REDACTED]@example.com/path?token=%5BREDACTED%5D&ok=1&session=%5BREDACTED%5D"
  end

  test "browser resource metadata renders redacted URL and resource scope" do
    confirmation = %{
      "params_summary" => %{
        "session_id" => "session-1",
        "url" => "https://user:pass@example.com/path?token=raw",
        "max_bytes" => 128,
        "resource_refs" => [
          %{
            "origin_kind" => "remote_url",
            "operation_class" => "browser_navigate",
            "access_mode" => "fetch",
            "scope" => %{"kind" => "url_prefix", "value" => "https://example.com/"},
            "downstream_consumer" => "browser_navigator"
          }
        ]
      }
    }

    lines = ResourceMetadata.lines(confirmation)

    assert "Browser session: session-1" in lines

    assert Enum.any?(
             lines,
             &String.contains?(
               &1,
               "Browser target URL: https://[REDACTED]@example.com/path?token=%5BREDACTED%5D"
             )
           )

    assert Enum.any?(
             lines,
             &String.starts_with?(&1, "Browser resource remote_url browser_navigate")
           )
  end

  test "browser intent descriptors propose handoff without granting browser authority" do
    phrases = [
      "summarize the page at https://example.com",
      "screenshot https://example.com",
      "what does https://example.com look like",
      "render https://example.com",
      "extract markdown from https://example.com"
    ]

    for phrase <- phrases do
      candidates =
        Engine.collect_candidates(EvalFixtures.request(text: phrase, active_app: :allbert))

      assert candidate =
               Enum.find(
                 candidates,
                 &match?(
                   %{
                     kind: :app_intent,
                     app_id: :allbert_browser,
                     action_name: "browser_research_handoff"
                   },
                   &1
                 )
               )

      assert candidate.trace_metadata.descriptor.capability.permission == :read_only
      assert candidate.trace_metadata.descriptor.capability.confirmation == :not_required

      refute candidate.trace_metadata.descriptor.capability.permission in [
               :browser_session_start,
               :browser_navigate,
               :browser_interact
             ]
    end
  end

  defp restore_default_apps do
    _ = AppRegistry.register(AllbertAssist.App.CoreApp)
    _ = AppRegistry.register(StockSage.App)
  end

  defp restore_default_plugins do
    _ = PluginRegistry.register_module(StockSage.Plugin)
    _ = PluginRegistry.register_module(AllbertAssist.Plugins.Telegram)
    _ = PluginRegistry.register_module(AllbertAssist.Plugins.Email)
  end
end
