{:ok, _apps} = Application.ensure_all_started(:credo)

Code.require_file(
  Path.expand("../../../../../priv/credo_checks/settings_central_no_bypass.ex", __DIR__)
)

defmodule AllbertAssist.SettingsCentralNoBypassCheckTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Credo.Check.SettingsCentralNoBypass
  alias Credo.SourceFile

  test "flags operator env and app config bypasses in production source" do
    source = """
    defmodule Example.TraceBypass do
      def env, do: System.get_env("ALLBERT_TRACE_ENABLED")
      def setting, do: Application.get_env(:allbert_assist, "runtime.trace_default")
    end
    """

    issues =
      source
      |> SourceFile.parse("apps/allbert_assist/lib/example_trace_bypass.ex")
      |> SettingsCentralNoBypass.run([])

    assert Enum.any?(issues, &(&1.trigger == ~s("ALLBERT_TRACE_ENABLED")))
    assert Enum.any?(issues, &(&1.trigger == "Application.get_env"))
  end

  test "flags legacy trace enabled app-env windows" do
    source = """
    defmodule AllbertAssist.Trace do
      defp config_enabled? do
        :allbert_assist
        |> Application.get_env(__MODULE__, [])
        |> Keyword.get(:enabled, false)
      end
    end
    """

    issues =
      source
      |> SourceFile.parse("apps/allbert_assist/lib/allbert_assist/trace.ex")
      |> SettingsCentralNoBypass.run([])

    assert Enum.any?(issues, &(&1.message =~ "runtime.trace_default"))
  end

  test "flags dotted operator setting app-config literals without key allowlist updates" do
    source = """
    defmodule Example.FutureSettingBypass do
      def setting, do: Application.get_env(:allbert_assist, "future.operator_setting")
    end
    """

    issues =
      source
      |> SourceFile.parse("apps/allbert_assist/lib/example_future_setting_bypass.ex")
      |> SettingsCentralNoBypass.run([])

    assert Enum.any?(issues, &(&1.message =~ "future.operator_setting"))
  end

  test "flags unknown ALLBERT env reads unless explicitly classified as infra" do
    source = """
    defmodule Example.FutureEnvBypass do
      def future, do: System.get_env("ALLBERT_FUTURE_OPERATOR_TOGGLE")
      def home, do: System.get_env("ALLBERT_HOME")
    end
    """

    issues =
      source
      |> SourceFile.parse("apps/allbert_assist/lib/example_future_env_bypass.ex")
      |> SettingsCentralNoBypass.run([])

    assert Enum.any?(issues, &(&1.trigger == ~s("ALLBERT_FUTURE_OPERATOR_TOGGLE")))
    refute Enum.any?(issues, &(&1.trigger == ~s("ALLBERT_HOME")))
  end

  test "allows tests and non-operator environment reads" do
    test_source = """
    defmodule ExampleTest do
      def home, do: System.get_env("ALLBERT_HOME")
      def trace, do: System.get_env("ALLBERT_TRACE_ENABLED")
    end
    """

    production_source = """
    defmodule ExampleHome do
      def home, do: System.get_env("ALLBERT_HOME")
    end
    """

    assert [] =
             test_source
             |> SourceFile.parse("apps/allbert_assist/test/example_test.exs")
             |> SettingsCentralNoBypass.run([])

    assert [] =
             production_source
             |> SourceFile.parse("apps/allbert_assist/lib/example_home.ex")
             |> SettingsCentralNoBypass.run([])
  end

  test "flags unknown non-ALLBERT operator env reads in production source" do
    source = """
    defmodule Example.NovelEnvBypass do
      def toggle, do: System.get_env("OPERATOR_FEATURE_TOGGLE")
    end
    """

    issues =
      source
      |> SourceFile.parse("apps/allbert_assist/lib/example_novel_env_bypass.ex")
      |> SettingsCentralNoBypass.run([])

    assert Enum.any?(issues, &(&1.trigger == ~s("OPERATOR_FEATURE_TOGGLE")))
  end

  test "flags single-segment operator setting keys matching a known namespace root" do
    source = """
    defmodule Example.SingleSegmentSettingBypass do
      def setting, do: Application.get_env(:allbert_assist, "runtime")
    end
    """

    issues =
      source
      |> SourceFile.parse(
        "apps/allbert_assist/lib/example_single_segment_setting_bypass.ex"
      )
      |> SettingsCentralNoBypass.run([])

    assert Enum.any?(issues, &(&1.trigger == "Application.get_env" and &1.message =~ "runtime"))
  end

  test "flags direct Settings.get reads in web production source" do
    source = """
    defmodule AllbertAssistWeb.Components.BadSettingsRead do
      def theme, do: AllbertAssist.Settings.get("workspace.theme.mode")
      def contrast, do: Settings.get("workspace.accessibility.high_contrast")
    end
    """

    issues =
      source
      |> SourceFile.parse(
        "apps/allbert_assist_web/lib/allbert_assist_web/components/bad_settings_read.ex"
      )
      |> SettingsCentralNoBypass.run([])

    assert Enum.count(issues, &(&1.trigger == "Settings.get")) == 2
  end

  test "flags direct web Settings Store and runtime config reads" do
    source = """
    defmodule AllbertAssistWeb.Components.BadStoreRead do
      def settings, do: AllbertAssist.Settings.Store.resolved_settings()
      def env, do: System.get_env("ALLBERT_TRACE_ENABLED")
      def app, do: Application.get_env(:allbert_assist, "workspace.theme.mode")
    end
    """

    issues =
      source
      |> SourceFile.parse(
        "apps/allbert_assist_web/lib/allbert_assist_web/components/bad_store_read.ex"
      )
      |> SettingsCentralNoBypass.run([])

    assert Enum.any?(issues, &(&1.trigger == "Settings.Store"))
    assert Enum.any?(issues, &(&1.trigger == "System.get_env"))
    assert Enum.any?(issues, &(&1.trigger == "Application.get_env"))
  end
end
