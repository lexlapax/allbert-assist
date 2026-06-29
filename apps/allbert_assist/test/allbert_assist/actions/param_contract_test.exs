defmodule AllbertAssist.Actions.ParamContractTest do
  use AllbertAssist.DataCase, async: false, lane: :app_env_serial
  @moduletag :app_env_serial
  @moduletag :param_contract

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Actions.ParamContract
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Agents.IntentAgent
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Intent.Router.FakeRouter
  alias AllbertAssist.Intent.Router.Outcome
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Discovery, as: PluginDiscovery
  alias AllbertAssist.Plugin.Entry, as: PluginEntry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings
  alias AllbertAssist.Workspace.Fragment.Guard

  defmodule StrictEcho do
    use Jido.Action,
      name: "param_contract_strict_echo",
      description: "Param contract strict echo fixture.",
      schema: [
        text: [type: :string, required: true],
        count: [type: :integer, default: 1]
      ]

    def capability do
      %{
        permission: :read_only,
        exposure: :agent,
        execution_mode: :read_only,
        skill_backed?: false,
        confirmation: :not_required
      }
    end

    @impl true
    def run(params, _context) do
      send(self(), {:strict_echo_ran, params})

      {:ok,
       %{
         message: "strict #{params.text}",
         status: :completed,
         params: params,
         actions: []
       }}
    end
  end

  defmodule NoParams do
    use Jido.Action,
      name: "param_contract_no_params",
      description: "Param contract no-param fixture.",
      schema: []

    def capability do
      %{
        permission: :read_only,
        exposure: :agent,
        execution_mode: :read_only,
        skill_backed?: false,
        confirmation: :not_required
      }
    end

    @impl true
    def run(params, _context) do
      send(self(), {:no_params_ran, params})
      {:ok, %{message: "no params", status: :completed, params: params, actions: []}}
    end
  end

  defmodule OpenMap do
    use Jido.Action,
      name: "param_contract_open_map",
      description: "Param contract open map fixture.",
      schema: [
        payload: [type: :map, required: true],
        rows: [type: {:list, :map}, required: false]
      ]

    def capability do
      %{
        permission: :read_only,
        exposure: :agent,
        execution_mode: :read_only,
        skill_backed?: false,
        confirmation: :not_required
      }
    end

    @impl true
    def run(params, _context) do
      send(self(), {:open_map_ran, params})
      {:ok, %{message: "open map", status: :completed, params: params, actions: []}}
    end
  end

  setup do
    original_confirmations = Application.get_env(:allbert_assist, Confirmations)
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)
    original_plugins = PluginRegistry.registered_plugins()
    notes_app_registered? = AppRegistry.known_app_id?(:notes_files)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-param-contract-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    PluginRegistry.clear()
    restore_shipped_plugins!()
    Guard.reset_for_test()

    unless notes_app_registered? do
      assert {:ok, :notes_files} = AppRegistry.register(AllbertNotesFiles.App)
    end

    assert {:ok, "example.param_contract"} =
             PluginRegistry.register_entry(%PluginEntry{
               plugin_id: "example.param_contract",
               display_name: "Example Param Contract Actions",
               version: "0.1.0",
               kind: "actions",
               source: :project,
               status: :enabled,
               trust_status: :trusted,
               actions: [StrictEcho, NoParams, OpenMap]
             })

    on_exit(fn ->
      restore_env(Confirmations, original_confirmations)
      restore_env(Paths, original_paths)
      restore_env(Settings, original_settings)
      restore_plugins!(original_plugins)
      Guard.reset_for_test()
      unless notes_app_registered?, do: AppRegistry.unregister(:notes_files)
      File.rm_rf!(root)
    end)

    for key <- [
          "permissions.email_send",
          "permissions.channel_message_send",
          "permissions.calendar_write",
          "permissions.notes_file_write"
        ] do
      assert {:ok, _setting} = Settings.put(key, "needs_confirmation", %{audit?: false})
    end

    :ok
  end

  test "valid string-keyed params normalize to schema atoms and Jido defaults reach run/2" do
    assert {:ok, response} = Runner.run("param_contract_strict_echo", %{"text" => "hello"}, %{})

    assert response.status == :completed
    assert response.params == %{text: "hello", count: 1}
    assert_received {:strict_echo_ran, %{text: "hello", count: 1}}

    IO.puts("param-contract-safe-key-normalization-001 status=pass valid_string_keys=true")
  end

  test "unknown string keys are rejected without creating atoms or running the body" do
    unknown_key = "allbert_unknown_param_#{System.unique_integer([:positive])}"
    refute_existing_atom!(unknown_key)

    assert {:ok, response} =
             Runner.run(
               "param_contract_strict_echo",
               %{"text" => "hello", unknown_key => "sk-secret-value"},
               %{}
             )

    assert response.status == :error

    assert response.error ==
             {:invalid_params, {:unknown_params, "param_contract_strict_echo", [unknown_key]}}

    assert response.message == "Action param_contract_strict_echo rejected: invalid params."
    refute response.message =~ "sk-secret-value"
    refute_received {:strict_echo_ran, _params}
    refute_existing_atom!(unknown_key)

    IO.puts("param-contract-enforced-at-runner-001 status=pass unknown_params=:invalid_params")
    IO.puts("param-contract-safe-key-normalization-001 status=pass atom_created=false")
  end

  test "typed validation failures are redacted invalid params before the body runs" do
    assert {:ok, response} =
             Runner.run("param_contract_strict_echo", %{text: "hello", count: "not-an-int"}, %{})

    assert response.status == :error

    assert {:invalid_params, {:validation_failed, "param_contract_strict_echo", _reason}} =
             response.error

    assert response.message == "Action param_contract_strict_echo rejected: invalid params."
    refute_received {:strict_echo_ran, _params}
  end

  test "empty schema actions are no-param actions unless explicitly dispositioned" do
    assert {:ok, ok} = Runner.run("param_contract_no_params", %{}, %{})
    assert ok.status == :completed
    assert ok.params == %{}
    assert_received {:no_params_ran, %{}}

    assert {:ok, rejected} =
             Runner.run("param_contract_no_params", %{"unexpected" => "value"}, %{})

    assert rejected.status == :error

    assert rejected.error ==
             {:invalid_params, {:unknown_params, "param_contract_no_params", ["unexpected"]}}

    refute_received {:no_params_ran, %{"unexpected" => "value"}}

    IO.puts("param-contract-empty-schema-001 status=pass disposition=no_params")
  end

  test "open map fields validate shape without atomizing nested string keys" do
    nested_key = "allbert_nested_param_#{System.unique_integer([:positive])}"
    refute_existing_atom!(nested_key)

    assert {:ok, response} =
             Runner.run(
               "param_contract_open_map",
               %{"payload" => %{nested_key => "value"}, "rows" => [%{"label" => "one"}]},
               %{}
             )

    assert response.status == :completed
    assert response.params.payload == %{nested_key => "value"}
    assert response.params.rows == [%{"label" => "one"}]
    assert_received {:open_map_ran, %{payload: %{^nested_key => "value"}}}
    refute_existing_atom!(nested_key)
  end

  test "registered action catalog has explicit schema dispositions" do
    catalog = ParamContract.catalog()
    names = Enum.map(catalog, & &1.name)
    empty_schema_entries = Enum.filter(catalog, &(&1.schema_type == :empty))

    assert Enum.uniq(names) == names
    assert empty_schema_entries != []
    assert Enum.all?(empty_schema_entries, &(&1.disposition == :no_params))

    refute Enum.any?(
             catalog,
             &(&1.disposition in [:json_schema_runtime_unsupported, :unsupported_schema])
           )
  end

  test "representative shipped valid requests replay with system context outside params" do
    context = runner_context()

    for {action_name, params, context_overrides, accepted_statuses} <- replay_cases() do
      assert {:ok, response} =
               Runner.run(action_name, params, Map.merge(context, context_overrides))

      refute match?({:invalid_params, _reason}, Map.get(response, :error)),
             "#{action_name} rejected representative valid params: #{inspect(response)}"

      assert response.status in accepted_statuses,
             "#{action_name} returned unexpected status #{inspect(response.status)}"
    end

    assert {:ok, rejected} =
             Runner.run(
               "send_email",
               %{to: "alice@example.com", body: "hello", user_id: "model-controlled"},
               context
             )

    assert rejected.status == :error
    assert {:invalid_params, {:unknown_params, "send_email", rejected_keys}} = rejected.error
    assert "user_id" in rejected_keys

    IO.puts(
      "param-contract-catalog-sweep-no-regression-001 status=pass " <>
        "replay_valid_requests=true context_source=runner_context"
    )
  end

  test "router-selected effectful actions keep request identity out of model params" do
    original = %{
      router: Application.get_env(:allbert_assist, :intent_router),
      outcome: Application.get_env(:allbert_assist, :intent_router_fake_outcome),
      override: Application.get_env(:allbert_assist, :intent_router_strategy_override)
    }

    Application.put_env(:allbert_assist, :intent_router, FakeRouter)
    Application.put_env(:allbert_assist, :intent_router_strategy_override, :two_stage_local)

    Application.put_env(
      :allbert_assist,
      :intent_router_fake_outcome,
      Outcome.execute(
        "send_email",
        %{to: "alice@example.com", body: "hello from route"},
        1.0
      )
    )

    try do
      assert {:ok, response} =
               IntentAgent.respond(%{
                 text: "send an email to alice@example.com saying hello from route",
                 channel: :test,
                 user_id: "local",
                 operator_id: "local",
                 thread_id: "thr-param-contract-route",
                 session_id: "sess-param-contract-route",
                 active_app: :allbert,
                 input_signal_id: "sig-param-contract-route"
               })

      assert response.status == :needs_confirmation
      assert response.decision.selected_action == "send_email"

      assert [%{name: "send_email", metadata: %{confirmation_id: confirmation_id}}] =
               response.actions

      assert {:ok, pending} = Confirmations.read(confirmation_id)
      assert pending["origin"]["user_id"] == "local"
      assert pending["origin"]["thread_id"] == "thr-param-contract-route"
      assert pending["origin"]["session_id"] == "sess-param-contract-route"

      for key <- ~w(user_id thread_id session_id) do
        refute Map.has_key?(pending["params_summary"], key)
        refute Map.has_key?(pending["resume_params_ref"], key)
      end

      IO.puts(
        "param-contract-catalog-sweep-no-regression-001 status=pass " <>
          "router_context_params=false"
      )
    after
      restore_env(:intent_router, original.router)
      restore_env(:intent_router_fake_outcome, original.outcome)
      restore_env(:intent_router_strategy_override, original.override)
    end
  end

  defp runner_context do
    %{
      actor: "local",
      channel: :test,
      user_id: "local",
      thread_id: "thr-param-contract",
      session_id: "sess-param-contract",
      request: %{
        user_id: "local",
        thread_id: "thr-param-contract",
        session_id: "sess-param-contract",
        channel: :test
      }
    }
  end

  defp replay_cases do
    [
      {"send_email", %{to: "alice@example.com", body: "hello"}, %{}, [:needs_confirmation]},
      {"send_channel_message", %{channel: "slack", target: "#eng", body: "hello"}, %{},
       [:needs_confirmation, :stopped]},
      {"create_calendar_event", %{title: "Sync", start: "tomorrow 10am"}, %{},
       [:needs_confirmation, :answer]},
      {"write_note", %{title: "Scratch", body: "hello"}, %{active_app: :notes_files},
       [:needs_confirmation]},
      {"list_provider_profiles", %{}, %{}, [:completed]}
    ]
  end

  defp refute_existing_atom!(key) do
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  defp restore_plugins!([]), do: restore_shipped_plugins!()

  defp restore_plugins!(plugins) do
    PluginRegistry.clear()

    Enum.each(plugins, fn plugin ->
      assert {:ok, _plugin_id} = PluginRegistry.register_entry(plugin)
    end)
  end

  defp restore_shipped_plugins! do
    PluginRegistry.clear()

    PluginDiscovery.shipped_modules()
    |> Enum.sort_by(fn {plugin_id, _module} -> plugin_id end)
    |> Enum.each(fn {_plugin_id, module} ->
      assert {:ok, _plugin_id} = PluginRegistry.register_module(module)
    end)
  end
end
