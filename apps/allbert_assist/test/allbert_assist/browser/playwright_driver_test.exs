defmodule AllbertAssist.Browser.PlaywrightDriverTest do
  use ExUnit.Case, async: true
  @moduletag :external_runtime_serial

  alias AllbertBrowser.Driver.Playwright

  @repo_root Path.expand("../../../../../", __DIR__)

  test "the bridge hides its console only on Windows" do
    node = fake_node()
    caller = self()

    port_open = fn command, options ->
      send(caller, {:port_options, options})
      Port.open(command, options)
    end

    for {os_type, hide?} <- [
          {{:win32, :nt}, true},
          {{:unix, :darwin}, false},
          {{:unix, :linux}, false}
        ] do
      assert {:ok, _result} =
               Playwright.verify(
                 node_path: node,
                 timeout_ms: 2_000,
                 os_type: os_type,
                 port_open: port_open
               )

      assert_receive {:port_options, options}
      assert :hide in options == hide?
    end
  end

  test "the bridge process preserves host-managed runtime paths" do
    node = fake_node()

    assert {:ok, result} =
             Playwright.verify(
               node_path: node,
               timeout_ms: 2_000,
               env: %{
                 "NODE_PATH" => "/opt/os/playwright/node_modules",
                 "PLAYWRIGHT_BROWSERS_PATH" => "/var/cache/os-playwright"
               }
             )

    assert result.node_path == "/opt/os/playwright/node_modules"
    assert result.playwright_browsers_path == "/var/cache/os-playwright"
  end

  test "a missing host Playwright package returns an actionable category" do
    node =
      System.find_executable("node") || flunk("Node is required for this external-runtime test")

    root = temp_root("missing-host-playwright")
    bridge = Path.join(root, "bridge.js")

    File.cp!(
      Path.join(@repo_root, "plugins/allbert.browser/priv/playwright_bridge/bridge.js"),
      bridge
    )

    assert {:error, {:playwright_unavailable, message}} =
             Playwright.verify(
               node_path: node,
               bridge_path: bridge,
               env: %{"NODE_PATH" => Path.join(root, "empty-node-modules")},
               timeout_ms: 2_000
             )

    assert message =~ "host Playwright package"
  end

  test "an operator version pin rejects a mismatched host Playwright package" do
    node =
      System.find_executable("node") || flunk("Node is required for this external-runtime test")

    root = temp_root("mismatched-host-playwright")
    bridge = Path.join(root, "bridge.js")
    modules = Path.join(root, "node_modules")
    playwright = Path.join(modules, "playwright")

    File.cp!(
      Path.join(@repo_root, "plugins/allbert.browser/priv/playwright_bridge/bridge.js"),
      bridge
    )

    File.mkdir_p!(playwright)
    File.write!(Path.join(playwright, "package.json"), ~s({"version":"1.58.2"}))
    File.write!(Path.join(playwright, "index.js"), "exports.chromium = {};\n")

    assert {:error, {:playwright_version_mismatch, message}} =
             Playwright.verify(
               node_path: node,
               bridge_path: bridge,
               version_pin: "1.58.1",
               env: %{"NODE_PATH" => modules},
               timeout_ms: 2_000
             )

    assert message =~ "1.58.2"
    assert message =~ "1.58.1"
  end

  defp fake_node do
    root = temp_root("fake-node")

    path = Path.join(root, "node")

    File.write!(path, ~S"""
    #!/bin/sh
    IFS= read -r request
    id="$(printf '%s' "$request" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
    printf '{"id":"%s","ok":true,"result":{"node_path":"%s","playwright_browsers_path":"%s"}}\n' \
      "$id" "${NODE_PATH:-missing}" "${PLAYWRIGHT_BROWSERS_PATH:-missing}"
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp temp_root(label) do
    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-playwright-#{label}-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
