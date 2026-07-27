defmodule AllbertAssistWeb.V12.CrossSurfaceFirstRunTest do
  use ExUnit.Case, async: false

  @moduletag :app_env_serial

  alias AllbertAssist.CLI.Tui
  alias AllbertAssist.FirstRun.Enablement
  alias AllbertAssist.FirstRun.Presentation
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssistWeb.Workspace.FirstRun, as: WorkspaceFirstRun

  @states [
    :local_ready,
    :byok_ready,
    :runtime_missing,
    :model_missing,
    :runtime_unhealthy,
    :below_hardware_floor
  ]

  @local %{
    profile: "local",
    provider: "local_ollama",
    provider_class: :local,
    verification: :doctor_healthy
  }
  @hosted %{
    profile: "fast",
    provider: "openai",
    provider_class: :hosted,
    verification: :configured_unverified
  }

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-v12-surface-matrix-#{System.unique_integer([:positive])}"
      )

    settings_env = Application.get_env(:allbert_assist, Settings)
    paths_env = Application.get_env(:allbert_assist, Paths)
    Application.put_env(:allbert_assist, Settings, root: root)
    Application.put_env(:allbert_assist, Paths, home: root)

    on_exit(fn ->
      restore(Settings, settings_env)
      restore(Paths, paths_env)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "all twelve fresh-Home cells agree across web, packaged/dev TUI, and CLI", %{root: root} do
    for model_state <- @states, hosted? <- [false, true] do
      reset_home!(root)

      assert {:ok, result} =
               Enablement.reconcile(model_state,
                 settings: matrix_settings(),
                 user_settings: %{},
                 local_selection: if(model_state == :local_ready, do: @local),
                 hosted_selection: if(hosted?, do: @hosted),
                 context: %{audit?: false}
               )

      assert result.state == expected_state(model_state, hosted?)
      assert_surface_contract(result, :web)
      assert_surface_contract(result, :cli)
      assert_surface_contract(result, :tui)

      # Both entry points are deliberately non-gating. The packaged launcher
      # calls this guard; the dev Mix task starts the same TUI child directly.
      assert :ok = Tui.readiness_guard(first_model_state: model_state)
      assert :ok = Mix.Tasks.Allbert.Tui.readiness_guard(first_model_state: model_state)

      assert WorkspaceFirstRun.default_destination(state: web_detect_state(result)) ==
               expected_web_destination(result)
    end
  end

  test "sticky-disabled and enabled-unavailable remain chat-ready on every surface", %{root: root} do
    for {stored, expected} <- [{false, :sticky_disabled}, {true, :enabled_unavailable}] do
      reset_home!(root)

      user = %{"intent" => %{"direct_answer_model_enabled" => stored}}

      assert {:ok, %{state: ^expected} = result} =
               Enablement.reconcile(:runtime_unhealthy,
                 settings: matrix_settings(),
                 user_settings: user,
                 hosted_selection: nil
               )

      for surface <- [:web, :tui, :cli], do: assert_surface_contract(result, surface)
      assert :ok = Tui.readiness_guard(first_model_state: :runtime_unhealthy)
    end
  end

  defp assert_surface_contract(result, surface) do
    presentation = Presentation.for(result, surface)
    assert length(presentation.primary_ctas) <= 1
    refute presentation.message =~ inspect(result.model_state)

    if result.state == :auto_enabled do
      assert presentation.primary_ctas == []
      assert presentation.message =~ "ready"
    else
      assert presentation.message =~ ~r/(fallback|disabled|unavailable)/
    end
  end

  defp web_detect_state(%{state: state})
       when state in [:needs_model, :nothing_detected, :below_floor],
       do: :first_model_not_ready

  defp web_detect_state(%{state: :enabled_unavailable}), do: :first_model_not_ready
  defp web_detect_state(_result), do: :product_ready

  defp expected_web_destination(%{state: state})
       when state in [:needs_model, :nothing_detected, :below_floor, :enabled_unavailable],
       do: "workspace:models"

  defp expected_web_destination(_result), do: nil

  defp expected_state(:local_ready, _hosted?), do: :auto_enabled
  defp expected_state(:byok_ready, true), do: :auto_enabled
  defp expected_state(:byok_ready, false), do: :nothing_detected
  defp expected_state(:runtime_missing, false), do: :nothing_detected
  defp expected_state(:below_hardware_floor, false), do: :below_floor
  defp expected_state(_state, true), do: :auto_enabled
  defp expected_state(_state, false), do: :needs_model

  defp reset_home!(root) do
    File.rm_rf!(root)
    File.mkdir_p!(root)
  end

  defp matrix_settings do
    %{
      "intent" => %{
        "direct_answer_model_enabled" => false,
        "model_assist_enabled" => false
      },
      "model_preferences" => %{
        "primary" => "local",
        "tasks" => %{"direct_answer" => ["local", "fast"]}
      },
      "providers" => %{
        "local_ollama" => %{
          "enabled" => true,
          "endpoint_kind" => "local_endpoint",
          "type" => "openai_compatible"
        },
        "openai" => %{
          "enabled" => true,
          "endpoint_kind" => "credentialed_remote",
          "credential_status" => :configured,
          "type" => "openai"
        }
      },
      "model_profiles" => %{
        "local" => %{
          "provider" => "local_ollama",
          "model" => "llama3.2:3b",
          "capabilities" => ["text_generation"]
        },
        "fast" => %{
          "provider" => "openai",
          "model" => "gpt-4o-mini",
          "capabilities" => ["text_generation"]
        }
      }
    }
  end

  defp restore(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore(module, value), do: Application.put_env(:allbert_assist, module, value)
end
