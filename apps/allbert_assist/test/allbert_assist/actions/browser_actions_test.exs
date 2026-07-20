defmodule AllbertAssist.Actions.BrowserActionsTest do
  use ExUnit.Case, async: false

  # v1.0.2 M8.2: browser actions resolve through a private ADR 0082 registry
  # context carried in the Runner context map (`:registry`), so this file no
  # longer clears or mutates the global Plugin.Registry. Lane audit (M8.2):
  # stays `home_fs_serial` — it still owns System tmp homes plus Application
  # env (Paths/Settings/Confirmations and the :allbert_browser driver), and it
  # drives the named AllbertBrowser.Supervisor/Session singletons.
  #
  # v1.0.3 M1 pilot (ADR 0086 contract 4): converted WITHIN the home_fs class
  # to the M8.3/M8.7 owned-home idiom — the per-test root is now
  # OS-pid-qualified (bare `System.unique_integer/1` restarts each BEAM boot,
  # so successive runs collided with STALE poisoned homes — the v1.0.2 M5
  # ranker-flake class; red-first proof recorded in the plan's M1 Build
  # Progress entry) and PRE-CLEANED before use. Contract-4 convert-vs-stay
  # DECISION (recorded): the file STAYS `home_fs_serial`. Reasons (seam
  # gaps, phase-3 intake): (a) the exercised production path reads the
  # `:allbert_browser, :driver` Application env at the ADR 0031-guarded
  # runner boundary — the driver read cannot take a process-scoped context
  # without extending contract 2 into the browser plugin's own processes,
  # which would weaken the ADR 0031 validation contract if done from test
  # scaffolding; (b) it drives the NAMED AllbertBrowser.Supervisor/Session
  # singletons, whose constructors do not yet take a name/registry override
  # (contract-3 seam recorded); and (c) the Paths/Settings/Confirmations
  # Application env writes are read by those browser processes — not by the
  # test process — so `ConfigContext` (deliberately not inherited) cannot
  # carry them across without those production seams. Within-class
  # ownership is proven by the "contract-4 owned-root proof" test below.
  @moduletag :home_fs_serial

  defmodule MissingBridgeDriver do
    def verify(_opts), do: {:error, {:playwright_bridge_missing, "/tmp/missing-bridge.js"}}
  end

  defmodule RuntimeFailureDriver do
    def verify(_opts), do: {:error, {:playwright_error, "Chromium launch failed"}}
  end

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.ResourceMetadata
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.TestSupport.RegistryIsolationFixtures, as: Fixtures

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_driver = Application.get_env(:allbert_browser, :driver)

    root = owned_root()

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_browser, :driver, AllbertBrowser.Driver.Stub)

    registry = Fixtures.start_isolated_registries(:browser_actions)
    assert "allbert.browser" = Fixtures.register_plugin!(registry, AllbertBrowser.Plugin)

    ensure_browser_supervisor()
    close_all_sessions()
    assert {:ok, _setting} = Settings.put("browser.enabled", true, %{audit?: false})

    on_exit(fn ->
      close_all_sessions()
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_env(Confirmations, original_confirmations_config)
      restore_env(:allbert_browser, :driver, original_driver)
      File.rm_rf!(root)
    end)

    %{root: root, registry: registry}
  end

  test "doctor live check persists ok state and start session requires approval", %{
    registry: registry
  } do
    assert {:ok, doctor} = Runner.run("browser_doctor", %{}, %{registry: registry})
    assert doctor.status == :completed
    assert doctor.doctor.live_check_status == :ok

    assert {:ok, pending} = Runner.run("browser_start_session", %{}, %{registry: registry})
    assert pending.status == :needs_confirmation
    assert is_binary(pending.confirmation_id)

    assert {:ok, started} =
             Runner.run("browser_start_session", %{}, %{
               confirmation: %{approved?: true},
               registry: registry
             })

    assert started.status == :completed
    assert is_binary(started.session_id)
  end

  test "doctor failure persists a structured unavailable error category", %{
    root: root,
    registry: registry
  } do
    Application.put_env(:allbert_browser, :driver, MissingBridgeDriver)

    assert {:ok, doctor} = Runner.run("browser_doctor", %{}, %{registry: registry})
    assert doctor.status == :completed
    assert doctor.doctor.status == :error
    assert doctor.doctor.live_check_status == :unavailable
    assert doctor.doctor.error_category == :playwright_bridge_missing
    assert doctor.doctor.error =~ "playwright_bridge_missing"

    assert {:ok, persisted} =
             root
             |> Path.join("cache/browser/doctor/state.json")
             |> File.read!()
             |> Jason.decode(keys: :atoms)

    assert persisted.error_category == "playwright_bridge_missing"
    assert persisted.live_check_status == "unavailable"

    assert {:ok, denied} =
             Runner.run("browser_start_session", %{}, %{
               confirmation: %{approved?: true},
               registry: registry
             })

    assert denied.status == :denied
    assert denied.error == {:doctor_not_ok, :unavailable}
  end

  test "doctor runtime failure persists a structured failed error category", %{registry: registry} do
    Application.put_env(:allbert_browser, :driver, RuntimeFailureDriver)

    assert {:ok, doctor} = Runner.run("browser_doctor", %{}, %{registry: registry})
    assert doctor.doctor.status == :error
    assert doctor.doctor.live_check_status == :failed
    assert doctor.doctor.error_category == :chromium_launch_failed
    assert doctor.doctor.error =~ "Chromium launch failed"
  end

  test "navigate, extract, and screenshot use the stub driver after approval", %{
    registry: registry
  } do
    assert {:ok, _doctor} = Runner.run("browser_doctor", %{}, %{registry: registry})

    assert {:ok, started} =
             Runner.run("browser_start_session", %{}, %{
               confirmation: %{approved?: true},
               registry: registry
             })

    assert {:ok, navigated} =
             Runner.run(
               "browser_navigate",
               %{session_id: started.session_id, url: "https://example.com/status"},
               %{confirmation: %{approved?: true}, registry: registry}
             )

    assert navigated.status == :completed
    assert navigated.page.url == "https://example.com/status"

    assert {:ok, extracted} =
             Runner.run("browser_extract", %{session_id: started.session_id, format: "text"}, %{
               registry: registry
             })

    assert extracted.status == :completed
    assert extracted.extraction.text =~ "Stub browser extraction"
    assert extracted.extraction.cache_ref =~ "cache://browser/#{started.session_id}/"

    assert {:ok, screenshot} =
             Runner.run("browser_screenshot", %{session_id: started.session_id}, %{
               registry: registry
             })

    assert screenshot.status == :completed
    assert screenshot.screenshot.redacted_credential_inputs?
    assert screenshot.screenshot.screenshot_ref =~ "cache://browser/#{started.session_id}/"

    assert {:ok, listed} = Runner.run("browser_list_sessions", %{}, %{registry: registry})
    assert [%{session_id: session_id, last_visited_host: "example.com"}] = listed.sessions
    assert session_id == started.session_id

    assert {:ok, closed} =
             Runner.run("browser_close_session", %{session_id: started.session_id}, %{
               registry: registry
             })

    assert closed.status == :completed
    assert {:ok, relisted} = Runner.run("browser_list_sessions", %{}, %{registry: registry})
    assert relisted.sessions == []
  end

  test "analyze browser screenshot bridges cached screenshot into vision input", %{
    root: root,
    registry: registry
  } do
    assert {:ok, _setting} =
             Settings.put("intent.direct_answer_model_enabled", true, %{audit?: false})

    assert {:ok, _setting} = Settings.put("vision.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("model_preferences.capabilities.vision_input", ["vision_fake"], %{
               audit?: false
             })

    assert {:ok, _doctor} = Runner.run("browser_doctor", %{}, %{registry: registry})

    assert {:ok, started} =
             Runner.run("browser_start_session", %{}, %{
               confirmation: %{approved?: true},
               registry: registry
             })

    assert {:ok, screenshot} =
             Runner.run("browser_screenshot", %{session_id: started.session_id}, %{
               registry: registry
             })

    screenshot_ref = screenshot.screenshot.screenshot_ref

    assert {:ok, analyzed} =
             Runner.run(
               "analyze_browser_screenshot",
               %{screenshot_ref: screenshot_ref, text: "What changed on this page?"},
               %{actor: "operator", user_id: "operator", registry: registry}
             )

    assert analyzed.status == :completed
    assert analyzed.message =~ "Fixture vision answer for 1 image input"
    assert analyzed.direct_answer.source == :model
    assert analyzed.direct_answer.model_resolution.capability == "vision_input"
    assert analyzed.browser_screenshot.screenshot_ref == screenshot_ref

    assert [
             %{
               resource_uri: "screen://capture/browser_" <> _hash,
               source: :browser_screenshot,
               origin_kind: :browser_screenshot,
               screenshot_ref: ^screenshot_ref,
               redacted_credential_inputs?: true
             }
           ] = analyzed.direct_answer.media.image_inputs

    assert [%{name: "analyze_browser_screenshot"} | _rest] = analyzed.actions
    refute inspect(analyzed) =~ root
  end

  test "session closes automatically after max lifetime", %{registry: registry} do
    assert {:ok, _setting} =
             Settings.put("browser.session.max_lifetime_ms", 1_000, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("browser.session.idle_timeout_ms", 60_000, %{audit?: false})

    assert {:ok, _doctor} = Runner.run("browser_doctor", %{}, %{registry: registry})

    assert {:ok, started} =
             Runner.run("browser_start_session", %{}, %{
               confirmation: %{approved?: true},
               registry: registry
             })

    assert eventually_session_closed?(started.session_id)
  end

  test "session closes automatically after idle timeout", %{registry: registry} do
    assert {:ok, _setting} =
             Settings.put("browser.session.max_lifetime_ms", 60_000, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("browser.session.idle_timeout_ms", 1_000, %{audit?: false})

    assert {:ok, _doctor} = Runner.run("browser_doctor", %{}, %{registry: registry})

    assert {:ok, started} =
             Runner.run("browser_start_session", %{}, %{
               confirmation: %{approved?: true},
               registry: registry
             })

    assert eventually_session_closed?(started.session_id)
  end

  test "click requires confirmation with selector and bounded visible label preview", %{
    registry: registry
  } do
    assert {:ok, _doctor} = Runner.run("browser_doctor", %{}, %{registry: registry})

    assert {:ok, started} =
             Runner.run("browser_start_session", %{}, %{
               confirmation: %{approved?: true},
               registry: registry
             })

    assert {:ok, _navigated} =
             Runner.run(
               "browser_navigate",
               %{session_id: started.session_id, url: "https://example.com/click"},
               %{confirmation: %{approved?: true}, registry: registry}
             )

    label = String.duplicate("Launch ", 40)

    assert {:ok, pending} =
             Runner.run(
               "browser_click",
               %{
                 session_id: started.session_id,
                 selector: "button.launch",
                 visible_label_preview: label
               },
               %{registry: registry}
             )

    assert pending.status == :needs_confirmation
    assert pending.confirmation["params_summary"]["selector"] == "button.launch"
    assert String.length(pending.confirmation["params_summary"]["visible_label_preview"]) == 200

    assert ResourceMetadata.lines(pending.confirmation)
           |> Enum.any?(&String.contains?(&1, "Browser selector"))

    assert {:ok, clicked} =
             Runner.run(
               "browser_click",
               %{
                 session_id: started.session_id,
                 selector: "button.launch",
                 visible_label_preview: label
               },
               %{confirmation: %{approved?: true}, registry: registry}
             )

    assert clicked.status == :completed
    assert clicked.click.selector == "button.launch"
  end

  test "form fill and download deny by default and require confirmation after opt-in", %{
    registry: registry
  } do
    assert {:ok, _doctor} = Runner.run("browser_doctor", %{}, %{registry: registry})

    assert {:ok, started} =
             Runner.run("browser_start_session", %{}, %{
               confirmation: %{approved?: true},
               registry: registry
             })

    assert {:ok, denied_fill} =
             Runner.run(
               "browser_fill",
               %{session_id: started.session_id, selector: "input[name=email]", value: "raw"},
               %{registry: registry}
             )

    assert denied_fill.status == :denied
    assert denied_fill.error == :browser_form_fill_disabled

    assert {:ok, denied_download} =
             Runner.run(
               "browser_download",
               %{session_id: started.session_id, url: "https://example.com/file.pdf"},
               %{registry: registry}
             )

    assert denied_download.status == :denied
    assert denied_download.error == :browser_download_disabled

    assert {:ok, _setting} = Settings.put("browser.form_fill.enabled", true, %{audit?: false})
    assert {:ok, _setting} = Settings.put("browser.download.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("permissions.browser_form_fill", "needs_confirmation", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("permissions.browser_download", "needs_confirmation", %{audit?: false})

    assert {:ok, pending_fill} =
             Runner.run(
               "browser_fill",
               %{
                 session_id: started.session_id,
                 selector: "input[name=email]",
                 value: "raw@example.com"
               },
               %{registry: registry}
             )

    assert pending_fill.status == :needs_confirmation
    assert pending_fill.confirmation["params_summary"]["value_redacted?"]

    assert {:ok, filled} =
             Runner.run(
               "browser_fill",
               %{
                 session_id: started.session_id,
                 selector: "input[name=email]",
                 value: "raw@example.com"
               },
               %{confirmation: %{approved?: true}, registry: registry}
             )

    assert filled.status == :completed
    assert filled.fill.value_redacted?

    assert {:ok, pending_download} =
             Runner.run(
               "browser_download",
               %{session_id: started.session_id, url: "https://example.com/file.pdf"},
               %{registry: registry}
             )

    assert pending_download.status == :needs_confirmation

    assert {:ok, downloaded} =
             Runner.run(
               "browser_download",
               %{
                 session_id: started.session_id,
                 url: "https://example.com/file.pdf",
                 filename: "file.pdf"
               },
               %{confirmation: %{approved?: true}, registry: registry}
             )

    assert downloaded.status == :completed
    assert downloaded.download.download_ref =~ "cache://browser/#{started.session_id}/"
  end

  test "navigation preflight denies private hosts before session call", %{registry: registry} do
    assert {:ok, _doctor} = Runner.run("browser_doctor", %{}, %{registry: registry})

    assert {:ok, response} =
             Runner.run(
               "browser_navigate",
               %{session_id: "missing", url: "https://127.0.0.1/status"},
               %{confirmation: %{approved?: true}, registry: registry}
             )

    assert response.status == :denied
    assert response.error == {:private_host_denied, "127.0.0.1"}
  end

  test "network policy allows same-origin subresources and denies cross-origin/private hosts" do
    assert AllbertBrowser.NetworkPolicy.allow_subresource?(
             "https://example.com/page",
             "https://example.com/app.js"
           )

    refute AllbertBrowser.NetworkPolicy.allow_subresource?(
             "https://example.com/page",
             "https://cdn.example.net/app.js"
           )

    refute AllbertBrowser.NetworkPolicy.allow_subresource?(
             "https://example.com/page",
             "https://127.0.0.1/app.js"
           )
  end

  test "navigation allowed domains are enforced when configured" do
    assert :ok = AllbertBrowser.NavigationPolicy.preflight("https://open.example/page")

    assert {:ok, _setting} =
             Settings.put("browser.navigation.allowed_domains", ["allowed.example"], %{
               audit?: false
             })

    assert :ok = AllbertBrowser.NavigationPolicy.preflight("https://allowed.example/page")

    assert {:error, {:host_not_allowlisted, "blocked.example"}} =
             AllbertBrowser.NavigationPolicy.preflight("https://blocked.example/page")
  end

  # ADR 0086 contract-4 owned-root proof (v1.0.3 M1, release.v103
  # `v103_pilot_home_fs`): (a) every Paths read this file exercises resolves
  # INSIDE the pid-qualified owned root — no dependence on the ambient suite
  # home or environment; (b) the idiom PRE-CLEANS the root, so a stale
  # poisoned home surviving from an earlier BEAM (bare-unique_integer
  # collision, the v1.0.2 M5 ranker-flake class) cannot leak settings into a
  # fresh test. Reverting (b)'s helper to the pre-conversion non-cleaning
  # idiom makes this test RED — the recorded red-first proof for the
  # home_fs class.
  test "contract-4 owned-root proof: pid-qualified pre-cleaned home owns every exercised root", %{
    root: root
  } do
    assert Paths.home() == root
    assert Paths.settings_root() == Path.join(root, "settings")
    assert Paths.confirmations_root() == Path.join(root, "confirmations")
    assert String.starts_with?(Paths.cache_root(), root)

    stale =
      Path.join(
        System.tmp_dir!(),
        "allbert-browser-actions-stale-probe-#{System.pid()}"
      )

    poison = Path.join([stale, "settings", "settings.yml"])
    File.mkdir_p!(Path.dirname(poison))
    File.write!(poison, "intent:\n  poisoned: true\n")

    assert ^stale = pre_cleaned_root(stale)
    refute File.exists?(poison)
    File.rm_rf!(stale)
  end

  # M8.3/M8.7 owned-home idiom (ADR 0086 contract 4): OS-pid-qualified and
  # pre-cleaned; the on_exit File.rm_rf!(root) in setup deletes it again so
  # runs never accumulate poison.
  defp owned_root do
    Path.join(
      System.tmp_dir!(),
      "allbert-browser-actions-#{System.pid()}-#{System.unique_integer([:positive])}"
    )
    |> pre_cleaned_root()
  end

  defp pre_cleaned_root(root) do
    File.rm_rf!(root)
    root
  end

  defp ensure_browser_supervisor do
    unless Process.whereis(AllbertBrowser.Supervisor) do
      start_supervised!(AllbertBrowser.Supervisor)
    end
  end

  defp close_all_sessions do
    Enum.each(AllbertBrowser.Session.list(), fn %{session_id: session_id} ->
      AllbertBrowser.Session.close(session_id)
    end)
  end

  defp eventually_session_closed?(session_id, attempts \\ 20)

  defp eventually_session_closed?(_session_id, 0), do: false

  defp eventually_session_closed?(session_id, attempts) do
    Process.sleep(100)

    if Enum.any?(AllbertBrowser.Session.list(), &(&1.session_id == session_id)) do
      eventually_session_closed?(session_id, attempts - 1)
    else
      true
    end
  end

  defp restore_env(module, key, nil), do: Application.delete_env(module, key)
  defp restore_env(module, key, value), do: Application.put_env(module, key, value)
  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
