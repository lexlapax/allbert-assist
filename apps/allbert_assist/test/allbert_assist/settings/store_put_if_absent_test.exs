defmodule AllbertAssist.Settings.StorePutIfAbsentTest do
  use ExUnit.Case, async: false

  @moduletag :app_env_serial

  alias AllbertAssist.Settings.{Audit, Store}

  @values %{
    "intent.direct_answer_model_enabled" => true,
    "intent.model_assist_enabled" => true,
    "model_preferences.tasks.direct_answer" => ["direct_answer_local"]
  }

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-put-if-absent-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    previous = Application.get_env(:allbert_assist, AllbertAssist.Settings)
    Application.put_env(:allbert_assist, AllbertAssist.Settings, root: root)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:allbert_assist, AllbertAssist.Settings, previous),
        else: Application.delete_env(:allbert_assist, AllbertAssist.Settings)

      File.rm_rf!(root)
    end)

    :ok
  end

  test "writes the absent subset once and preserves every stored value" do
    assert {:ok, _merged, _user, _diagnostics} =
             Store.put_user_setting("intent.model_assist_enabled", false, %{audit?: false})

    assert {:ok,
            %{
              written: [
                "intent.direct_answer_model_enabled",
                "model_preferences.tasks.direct_answer"
              ],
              present: %{"intent.model_assist_enabled" => false}
            }} = Store.put_user_settings_if_absent(@values, %{audit?: false})

    assert {:ok, user} = Store.read_user_settings()
    assert get_in(user, ["intent", "direct_answer_model_enabled"])
    refute get_in(user, ["intent", "model_assist_enabled"])
    assert get_in(user, ["model_preferences", "primary"]) == nil

    assert get_in(user, ["model_preferences", "tasks", "direct_answer"]) == [
             "direct_answer_local"
           ]

    assert {:ok, %{written: [], present: present}} =
             Store.put_user_settings_if_absent(@values, %{audit?: false})

    assert present == %{
             "intent.direct_answer_model_enabled" => true,
             "intent.model_assist_enabled" => false,
             "model_preferences.tasks.direct_answer" => ["direct_answer_local"]
           }
  end

  test "validation failure writes none of the absent subset" do
    invalid =
      Map.put(@values, "model_preferences.tasks.direct_answer", ["missing-profile"])

    assert {:error, _reason} = Store.put_user_settings_if_absent(invalid, %{audit?: false})
    assert {:ok, %{}} = Store.read_user_settings()
  end

  test "rejects every key outside the closed enablement set" do
    assert {:error, {:settings_if_absent_keys_not_allowed, ["agent.name"]}} =
             Store.put_user_settings_if_absent(%{"agent.name" => "surprise"}, %{audit?: false})

    assert {:ok, %{}} = Store.read_user_settings()
  end

  test "abstains atomically when consent became false or the selected primary changed" do
    assert {:ok, _merged, _user, _diagnostics} =
             Store.put_user_setting("intent.direct_answer_model_enabled", false, %{audit?: false})

    assert {:ok, %{disposition: :explicitly_disabled, written: []}} =
             Store.put_user_settings_if_absent(@values, %{audit?: false})

    assert {:ok, disabled_user} = Store.read_user_settings()
    assert get_in(disabled_user, ["intent", "direct_answer_model_enabled"]) == false
    assert get_in(disabled_user, ["intent", "model_assist_enabled"]) == nil
    assert get_in(disabled_user, ["model_preferences", "tasks", "direct_answer"]) == nil

    File.rm_rf!(Store.root())

    assert {:ok, _merged, _user, _diagnostics} =
             Store.put_user_setting("model_preferences.tasks.direct_answer", ["fast"], %{
               audit?: false
             })

    assert {:ok, %{disposition: :selection_changed, written: []}} =
             Store.put_user_settings_if_absent(@values, %{audit?: false})

    assert {:ok, changed_user} = Store.read_user_settings()
    assert get_in(changed_user, ["model_preferences", "tasks", "direct_answer"]) == ["fast"]
    assert get_in(changed_user, ["intent", "direct_answer_model_enabled"]) == nil
    assert get_in(changed_user, ["intent", "model_assist_enabled"]) == nil
  end

  test "audit contains one row per applied key and one provenance envelope" do
    assert {:ok, %{written: written}} =
             Store.put_user_settings_if_absent(@values, %{actor: "first-run"})

    audit = File.read!(Audit.audit_path())
    assert length(written) == 3
    assert audit =~ "intent.direct_answer_model_enabled"
    assert audit =~ "intent.model_assist_enabled"
    assert audit =~ "model_preferences.tasks.direct_answer"
    assert audit =~ "settings.transaction"
    assert audit =~ "applied:"

    assert length(Regex.scan(~r/^## .* intent\.direct_answer_model_enabled$/m, audit)) == 1
    assert length(Regex.scan(~r/^## .* intent\.model_assist_enabled$/m, audit)) == 1
    assert length(Regex.scan(~r/^## .* model_preferences\.tasks\.direct_answer$/m, audit)) == 1
    assert length(Regex.scan(~r/^## .* settings\.transaction$/m, audit)) == 1
  end

  test "a concurrent explicit disable cannot be lost by auto-enablement" do
    for _attempt <- 1..10 do
      File.rm_rf!(Store.root())

      starter = self()

      auto =
        Task.async(fn ->
          send(starter, {:ready, self()})
          receive do: (:go -> Store.put_user_settings_if_absent(@values, %{audit?: false}))
        end)

      disable =
        Task.async(fn ->
          send(starter, {:ready, self()})

          receive do
            :go ->
              Store.put_user_setting(
                "intent.direct_answer_model_enabled",
                false,
                %{audit?: false}
              )
          end
        end)

      assert_receive {:ready, auto_pid}
      assert_receive {:ready, disable_pid}
      send(auto_pid, :go)
      send(disable_pid, :go)

      assert match?({:ok, _}, Task.await(auto))
      assert match?({:ok, _, _, _}, Task.await(disable))
      assert {:ok, user} = Store.read_user_settings()
      refute get_in(user, ["intent", "direct_answer_model_enabled"])
    end
  end
end
