defmodule AllbertAssist.Settings.VersionContractTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragment
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.SchemaDiff
  alias AllbertAssist.Settings.Store
  alias AllbertAssist.Settings.VersionContract

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-version-contract-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Settings, root: root)

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "fragment schema_version defaults to 1 and reconciles legacy schema rows" do
    fragment =
      Fragment.new!(%{
        id: "core:sample",
        owner: "sample",
        source: :core,
        schema: %{
          "sample.enabled" => %{
            type: :boolean,
            default: false,
            writable?: true,
            sensitive?: false
          }
        }
      })

    assert fragment.schema_version == 1

    reconciled =
      Fragment.new!(%{
        id: "core:sample",
        owner: "sample",
        source: :core,
        schema: %{
          "sample.schema_version" => %{
            type: :positive_integer,
            default: 3,
            writable?: false,
            sensitive?: false
          }
        }
      })

    assert reconciled.schema_version == 3
  end

  test "generated inventory reports every registered fragment at version 1" do
    report = VersionContract.status()

    assert report.status == :ok
    assert report.total_fragments == length(Fragments.registered_fragments())
    assert report.counts.current == report.total_fragments
    assert report.counts.forward == 0
    assert Enum.all?(report.inventory, &(&1.known_schema_version == 1))
    assert Enum.any?(report.inventory, &(&1.fragment_id == "core:artifacts"))
  end

  test "unversioned stored fragments are version 1 and older versions are pending" do
    fragment =
      Fragment.new!(%{
        id: "core:future",
        owner: "future",
        source: :core,
        schema_version: 2,
        schema: %{
          "future.enabled" => %{
            type: :boolean,
            default: false,
            writable?: true,
            sensitive?: false
          }
        }
      })

    report = VersionContract.status(fragments: [fragment])

    assert report.status == :pending

    assert [%{status: :pending, stored_schema_version: 1, known_schema_version: 2}] =
             report.inventory
  end

  test "forward or invalid stored fragment versions fail closed" do
    user_settings = %{"artifacts" => %{"schema_version" => 2}}

    assert {:error, {:settings_version_contract_blocked, diagnostics}} =
             VersionContract.reject_forward_versions(user_settings)

    assert [
             %{
               code: :settings_schema_version_forward,
               fragment_id: "core:artifacts",
               severity: :error
             }
           ] = diagnostics

    invalid_settings = %{"artifacts" => %{"schema_version" => "2"}}

    assert {:error, {:settings_version_contract_blocked, invalid_diagnostics}} =
             VersionContract.reject_forward_versions(invalid_settings)

    assert [%{code: :settings_schema_version_invalid}] = invalid_diagnostics
  end

  test "store refuses to open a Home with a forward settings fragment version", %{root: root} do
    settings_path = Path.join(root, "settings.yml")
    File.mkdir_p!(Path.dirname(settings_path))
    File.write!(settings_path, "artifacts:\n  schema_version: 2\n")

    assert {:error, {:settings_version_contract_blocked, diagnostics}} =
             Store.resolved_settings()

    assert [%{fragment_id: "core:artifacts", status: :forward}] = diagnostics
  end

  test "schema diff accepts additive keys and rejects non-additive changes" do
    before_schema = %{
      "sample.enabled" => %{
        type: :boolean,
        default: false,
        writable?: true,
        sensitive?: false
      }
    }

    additive_schema =
      Map.put(before_schema, "sample.max_items", %{
        type: :positive_integer,
        default: 10,
        writable?: true,
        sensitive?: false
      })

    assert {:ok, %{status: :additive, added: ["sample.max_items"]}} =
             SchemaDiff.compare(before_schema, additive_schema)

    changed_schema =
      put_in(before_schema, ["sample.enabled", :default], true)

    assert {:error, %{status: :non_additive, changed: [%{key: "sample.enabled"}]}} =
             SchemaDiff.compare(before_schema, changed_schema)

    assert {:error, %{removed: ["sample.enabled"]}} = SchemaDiff.compare(before_schema, %{})
    refute SchemaDiff.additive_only?(before_schema, changed_schema)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
