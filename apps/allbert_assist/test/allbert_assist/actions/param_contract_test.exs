defmodule AllbertAssist.Actions.ParamContractTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial
  @moduletag :param_contract

  alias AllbertAssist.Actions.ParamContract
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Plugin.Discovery, as: PluginDiscovery
  alias AllbertAssist.Plugin.Entry, as: PluginEntry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry

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
    original_plugins = PluginRegistry.registered_plugins()

    PluginRegistry.clear()

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
      restore_plugins!(original_plugins)
    end)

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
    empty_schema_count = Enum.count(catalog, &(&1.disposition == :no_params))

    assert Enum.uniq(names) == names
    assert empty_schema_count > 0

    refute Enum.any?(
             catalog,
             &(&1.disposition in [:json_schema_runtime_unsupported, :unsupported_schema])
           )

    IO.puts(
      "param-contract-catalog-sweep-no-regression-001 status=pass " <>
        "actions=#{length(catalog)} empty_schema=#{empty_schema_count} unsupported=0"
    )
  end

  defp refute_existing_atom!(key) do
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
  end

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
