defmodule AllbertAssist.Settings.KeyCustodyTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.KeyCustody
  alias AllbertAssist.Settings.Secrets

  @env_vars [
    "ALLBERT_HOME",
    "ALLBERT_HOME_DIR",
    "ALLBERT_SETTINGS_ROOT",
    "ALLBERT_SETTINGS_MASTER_KEY"
  ]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_audit_config = Application.get_env(:allbert_assist, AllbertAssist.Settings.Audit)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)
    Application.delete_env(:allbert_assist, AllbertAssist.Settings.Audit)

    home = temp_path("home")
    System.put_env("ALLBERT_HOME", home)
    KeyCustody.invalidate(:all)

    on_exit(fn ->
      KeyCustody.invalidate(:all)
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
      restore_app_env(AllbertAssist.Settings.Audit, original_audit_config)
    end)

    {:ok, home: home}
  end

  test "fetch serves secrets from custody and invalidates after writes and deletes" do
    ref = "secret://channels/telegram/bot_token"

    assert Secrets.status(ref) == :missing

    assert {:ok, %{status: :configured}} =
             Secrets.put_secret(ref, "bot-token-v1", %{actor: "local", channel: :test})

    assert {:ok, "bot-token-v1"} = Secrets.get_secret(ref, %{actor: "reader", channel: :test})
    assert {:ok, true} = KeyCustody.secure_compare(ref, "bot-token-v1")
    assert {:ok, false} = KeyCustody.secure_compare(ref, "bot-token-v2")

    assert {:ok, %{status: :configured}} =
             Secrets.put_secret(ref, "bot-token-v2", %{actor: "local", channel: :test})

    assert {:ok, "bot-token-v2"} = Secrets.get_secret(ref, %{actor: "reader", channel: :test})

    assert {:ok, %{status: :missing}} = Secrets.delete_secret(ref)
    assert {:error, {:secret_not_found, ^ref}} = Secrets.get_secret(ref)
    assert Secrets.status(ref) == :missing
  end

  test "custody state and status inspection do not expose secret material" do
    ref = "secret://providers/openai/api_key"
    raw_secret = "sk-no-leak-from-custody"

    assert {:ok, %{status: :configured}} =
             Secrets.put_secret(ref, raw_secret, %{actor: "local", channel: :test})

    assert {:ok, ^raw_secret} = Secrets.get_secret(ref, %{actor: "reader", channel: :test})

    pid = Process.whereis(KeyCustody)
    state_text = inspect(:sys.get_state(pid))
    status_text = inspect(:sys.get_status(pid))

    refute state_text =~ raw_secret
    refute status_text =~ raw_secret
    assert state_text =~ "secret_count"
    assert status_text =~ "secret_count"
  end

  test "fetches are audited without raw secret material", %{home: home} do
    ref = "secret://mcp/demo/bearer_token"

    assert {:ok, %{status: :configured}} =
             Secrets.put_secret(ref, "mcp-fetch-token", %{actor: "writer", channel: :test})

    assert {:ok, "mcp-fetch-token"} =
             Secrets.get_secret(ref, %{actor: "reader", channel: :test})

    audit_path = audit_path(home)
    audit = File.read!(audit_path)

    assert audit =~ ref
    assert audit =~ "actor: reader"
    assert audit =~ "new: fetched"
    refute audit =~ "mcp-fetch-token"
  end

  test "path changes force a reload instead of reusing stale custody state" do
    first_ref = "secret://providers/openai/api_key"
    second_ref = "secret://providers/gemini/api_key"
    second_home = temp_path("second-home")
    on_exit(fn -> File.rm_rf!(second_home) end)

    assert {:ok, %{status: :configured}} =
             Secrets.put_secret(first_ref, "first-home-secret", %{audit?: false})

    assert {:ok, "first-home-secret"} = Secrets.get_secret(first_ref)

    System.put_env("ALLBERT_HOME", second_home)

    assert Secrets.status(first_ref) == :missing

    assert {:ok, %{status: :configured}} =
             Secrets.put_secret(second_ref, "second-home-secret", %{audit?: false})

    assert {:ok, "second-home-secret"} = Secrets.get_secret(second_ref)
    assert {:error, {:secret_not_found, ^first_ref}} = Secrets.get_secret(first_ref)
  end

  defp audit_path(home) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    Path.join([home, "settings", "audit", "#{Calendar.strftime(now, "%Y-%m")}.md"])
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-key-custody-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_env(original_env) do
    Enum.each(original_env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
