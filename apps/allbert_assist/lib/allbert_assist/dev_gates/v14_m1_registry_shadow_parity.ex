defmodule AllbertAssist.DevGates.V14M1RegistryShadowParity do
  @moduledoc """
  Deterministic evidence helpers for the v1.4 M1.a2 shadow Pack checkpoint.

  This module owns generated test fixtures and frozen-ledger comparison. The
  production LegacyAdapter never reads either fixture.
  """

  alias AllbertAssist.Actions.Capability
  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.DevGates.V14M0RegistryLedger
  alias AllbertAssist.Extensions.Registry, as: ExtensionsRegistry
  alias AllbertAssist.Licenses
  alias AllbertAssist.Objectives.CanonicalJSON

  alias AllbertAssist.Pack.{
    Canonical,
    OTPMetadata,
    Projection,
    Registry,
    RowSchemas
  }

  alias AllbertAssist.Pack.OTPMetadata.{ReleaseApplication, ReleaseSpec}
  alias AllbertAssist.Pack.Registry.{Candidate, Snapshot}
  alias AllbertAssist.Plugin.Entry, as: PluginEntry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings.Fragment, as: SettingsFragment
  alias AllbertAssist.Settings.Fragments, as: SettingsFragments

  @schema_version 1
  @normalization "v14_pack_row_schema_contract_v1"
  @row_schema_contract_domain "allbert.pack.row-schema-contract.v1\0"
  @repo_root Path.expand("../../../../..", __DIR__)
  @closed_applications [
    :allbert_kernel,
    :allbert_assist,
    :allbert_composition,
    :allbert_assist_web
  ]

  @type registry_process :: pid() | {atom(), node()} | nil
  @type dynamic_child ::
          {:undefined, pid() | :restarting, :worker | :supervisor, [module()] | :dynamic}
  @type legacy_observation :: %{
          action_capabilities: [Capability.t()],
          action_modules: nonempty_list(module()),
          app_children: [dynamic_child()],
          app_diagnostics: map(),
          app_registry_pid: registry_process(),
          apps: [AppRegistry.app_entry()],
          extensions: ExtensionsRegistry.contribution_summary(),
          plugin_children: [dynamic_child()],
          plugin_diagnostics: map(),
          plugin_registry_pid: registry_process(),
          plugins: [PluginEntry.t()],
          settings_cache: term(),
          settings_fragments: [SettingsFragment.t()]
        }

  @type row_schema_contract_field :: %{
          required(String.t()) => boolean() | nil | String.t() | non_neg_integer() | [String.t()]
        }
  @type row_schema_contract_identity :: %{required(String.t()) => String.t()}
  @type row_schema_contract_order :: %{
          required(String.t()) => String.t() | [String.t()]
        }
  @type row_schema_contract_entry :: %{
          required(String.t()) =>
            boolean()
            | nil
            | String.t()
            | [row_schema_contract_field()]
            | row_schema_contract_identity()
            | row_schema_contract_order()
        }
  @type row_schema_contract_fixture :: %{
          required(String.t()) => String.t() | nonempty_list(row_schema_contract_entry()) | 1
        }

  @doc "Build the sealed source projection used by the M1.a2 shadow gate."
  @spec source_closed_projection!() :: Projection.Closed.t()
  def source_closed_projection! do
    catalog = Licenses.load_catalog(repo_root: @repo_root) |> value!(:source_catalog)
    applications = Enum.map(@closed_applications, &read_source_application!/1)
    application_index = Map.new(applications, &{Atom.to_string(&1.application), &1})

    components =
      catalog
      |> Map.fetch!("components")
      |> Enum.map(fn component ->
        with %{"application" => application_name, "pack" => pack} when is_map(pack) <- component,
             {:ok, application} <- Map.fetch(application_index, application_name) do
          Map.put(component, "pack", Map.put(pack, "app_sha256", application.sha256))
        else
          _other -> component
        end
      end)

    release = %ReleaseSpec{
      name: "allbert",
      version: applications |> hd() |> Map.fetch!(:version),
      erts_version: System.otp_release(),
      applications:
        Enum.map(applications, fn application ->
          %ReleaseApplication{
            application: application.application,
            version: application.version,
            start_mode: :permanent,
            included_applications: application.included_applications
          }
        end)
    }

    Projection.reconcile_closed(components, applications, release,
      sealed: true,
      closed_applications: @closed_applications,
      effective_env_fetcher: source_env_fetcher(applications)
    )
    |> value!(:closed_pack_projection)
  end

  @doc "Check live/frozen M0 equality before an observation window and return bounded binding evidence."
  @spec prepare_m0!() :: %{
          schema_version: 1,
          payload_sha256: String.t(),
          payload: map(),
          action_rows: [map()]
        }
  def prepare_m0! do
    :ok = V14M0RegistryLedger.check!()
    frozen = V14M0RegistryLedger.load_frozen!()

    %{
      schema_version: 1,
      payload_sha256: get_in(frozen, ["digests", "payload_sha256"]),
      payload: Map.fetch!(frozen, "payload"),
      action_rows: get_in(frozen, ["payload", "actions", "rows"])
    }
  end

  @doc "Verify every effective binding against its exact frozen M0 row without atomizing fixture text."
  @spec verify_m0_bindings!(Candidate.t(), map()) :: :ok
  def verify_m0_bindings!(%Candidate{action_bindings: bindings}, %{
        schema_version: 1,
        payload_sha256: payload_sha256,
        payload: payload,
        action_rows: rows
      })
      when is_binary(payload_sha256) and is_map(payload) and is_list(rows) do
    expected_indices = rows |> Enum.with_index(1) |> Enum.map(&elem(&1, 1))

    unless V14M0RegistryLedger.digest(payload) == payload_sha256 and
             get_in(payload, ["actions", "rows"]) == rows and
             Enum.map(rows, &Map.fetch!(&1, "index")) == expected_indices and
             Enum.map(bindings, & &1.legacy_index) == expected_indices do
      raise "v1.4 M1.a2 prepared M0 payload or binding indices are not exact"
    end

    Enum.zip(bindings, rows)
    |> Enum.each(fn {binding, row} -> verify_m0_binding!(binding, row) end)

    :ok
  end

  def verify_m0_bindings!(_candidate, _prepared) do
    raise "invalid v1.4 M1.a2 prepared M0 binding evidence"
  end

  @doc "Capture the observable legacy state used by the zero-mutation assertion."
  @spec legacy_observation(keyword()) :: legacy_observation()
  def legacy_observation(context) when is_list(context) do
    app_opts = Keyword.fetch!(context, :app)
    plugin_opts = Keyword.fetch!(context, :plugin)
    {:ok, plugin_entries} = PluginRegistry.ordered_entries(plugin_opts)

    %{
      app_registry_pid: GenServer.whereis(Keyword.fetch!(app_opts, :server)),
      plugin_registry_pid: GenServer.whereis(Keyword.fetch!(plugin_opts, :server)),
      apps: AppRegistry.registered_apps(app_opts),
      app_diagnostics: AppRegistry.diagnostics(app_opts),
      plugins: plugin_entries,
      plugin_diagnostics: PluginRegistry.diagnostics(plugin_opts),
      action_modules: ActionsRegistry.modules(context),
      action_capabilities: ActionsRegistry.capabilities(context),
      extensions: ExtensionsRegistry.contributions(app: app_opts, plugin: plugin_opts),
      settings_fragments: SettingsFragments.registered_fragments(context),
      settings_cache:
        :persistent_term.get({SettingsFragments, :default_composition}, :not_cached),
      app_children: DynamicSupervisor.which_children(AllbertAssist.App.DynamicSupervisor),
      plugin_children: DynamicSupervisor.which_children(AllbertAssist.Plugin.ChildSupervisor)
    }
  end

  @doc "Finalize equal source/private/overlay candidates and return the mandatory shadow identities."
  @spec verify_shadow!(
          Projection.Closed.t(),
          Candidate.t(),
          Candidate.t(),
          Candidate.t(),
          map(),
          GenServer.server()
        ) :: map()
  def verify_shadow!(
        %Projection.Closed{} = closed,
        %Candidate{} = source_candidate,
        %Candidate{} = private_candidate,
        %Candidate{} = overlay_candidate,
        prepared_m0,
        registry_server
      ) do
    :ok = Projection.validate_closed(closed)

    unless source_candidate == private_candidate do
      raise "v1.4 M1.a2 source/private candidate mismatch"
    end

    unless private_candidate == overlay_candidate do
      raise "v1.4 M1.a2 populated overlay changed the captured candidate"
    end

    :ok = verify_m0_bindings!(source_candidate, prepared_m0)

    {:ok, %{phase: :collecting, publication: :shadow, behavior_digest: nil}} =
      Registry.status(server: registry_server)

    {:ok, %Snapshot{} = snapshot} = Registry.finalize(source_candidate, server: registry_server)
    {:ok, ^snapshot} = Registry.finalize(private_candidate, server: registry_server)
    {:ok, ^snapshot} = Registry.finalize(overlay_candidate, server: registry_server)
    {:ok, ^snapshot} = Registry.snapshot(server: registry_server)
    behavior_digest = snapshot.behavior_digest

    {:ok,
     %{
       phase: :finalized,
       publication: :shadow,
       behavior_digest: ^behavior_digest
     }} = Registry.status(server: registry_server)

    {:ok, snapshot_bytes} = Canonical.snapshot_bytes(snapshot)
    fixture = load_row_schema_contract_fixture!()

    %{
      pack_projection_sha256: closed.projection_sha256,
      pack_closure_sha256: closed.closure_sha256,
      snapshot_bytes_sha256: sha256(snapshot_bytes),
      behavior_digest: snapshot.behavior_digest,
      candidate_counts: candidate_counts(source_candidate),
      m0_registry_payload_sha256: prepared_m0.payload_sha256,
      row_schema_fixture_sha256: row_schema_contract_fixture_path() |> File.read!() |> sha256(),
      row_schema_contract_sha256: Map.fetch!(fixture, "schema_contract_sha256"),
      private_registry_parity: :pass,
      overlay_exclusion_and_precedence: :pass
    }
  end

  def verify_shadow!(_closed, _source, _private, _overlay, _prepared_m0, _registry_server) do
    raise "invalid v1.4 M1.a2 shadow evidence input"
  end

  @doc "Return the repository-owned row-schema contract fixture path."
  @spec row_schema_contract_fixture_path() :: Path.t()
  def row_schema_contract_fixture_path do
    Path.join(
      @repo_root,
      "apps/allbert_kernel/test/fixtures/v1.4/pack_row_schema_contract.json"
    )
  end

  @doc "Build the deterministic row-schema contract fixture value."
  @spec row_schema_contract_fixture() :: row_schema_contract_fixture()
  def row_schema_contract_fixture do
    contract = RowSchemas.schema_contract()

    %{
      "schema_version" => @schema_version,
      "normalization" => @normalization,
      "schema_contract" => contract,
      "schema_contract_sha256" => row_schema_contract_digest(contract)
    }
  end

  @doc "Load and self-validate the committed row-schema contract fixture."
  @spec load_row_schema_contract_fixture!() :: map()
  def load_row_schema_contract_fixture! do
    frozen =
      row_schema_contract_fixture_path()
      |> File.read!()
      |> Jason.decode!()

    expected_keys =
      ~w[normalization schema_contract schema_contract_sha256 schema_version]

    valid? =
      is_map(frozen) and
        Enum.sort(Map.keys(frozen)) == expected_keys and
        frozen["schema_version"] == @schema_version and
        frozen["normalization"] == @normalization and
        is_list(frozen["schema_contract"]) and
        frozen["schema_contract_sha256"] ==
          row_schema_contract_digest(frozen["schema_contract"])

    if valid?, do: frozen, else: raise("invalid v1.4 Pack row-schema contract fixture")
  end

  @doc "Fail when the committed row-schema contract differs from live code."
  @spec check_row_schema_contract_fixture!() :: :ok
  def check_row_schema_contract_fixture! do
    if load_row_schema_contract_fixture!() == row_schema_contract_fixture() do
      :ok
    else
      raise "v1.4 Pack row-schema contract fixture drift"
    end
  end

  @doc "Regenerate the committed row-schema contract fixture."
  @spec write_row_schema_contract_fixture!(Path.t()) :: row_schema_contract_fixture()
  def write_row_schema_contract_fixture!(path \\ row_schema_contract_fixture_path()) do
    fixture = row_schema_contract_fixture()
    File.mkdir_p!(Path.dirname(path))

    bytes =
      fixture
      |> CanonicalJSON.encode()
      |> Jason.Formatter.pretty_print()
      |> Kernel.<>("\n")

    File.write!(path, bytes)
    fixture
  end

  defp row_schema_contract_digest(contract) do
    @row_schema_contract_domain
    |> Kernel.<>(CanonicalJSON.encode(contract))
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp verify_m0_binding!(binding, row) do
    projection = %{
      "index" => binding.legacy_index,
      "name" => binding.name,
      "module" => module_name(binding.module),
      "source_bucket" => m0_source_bucket(binding.source_lane),
      "capability" => binding.normalized_capability,
      "input_schema_sha256" => binding.input_schema_sha256,
      "output_schema_sha256" => binding.output_schema_sha256
    }

    expected_digest = V14M0RegistryLedger.digest(row)
    actual_digest = V14M0RegistryLedger.digest(projection)

    unless actual_digest == expected_digest and binding.m0_row_sha256 == expected_digest do
      raise "v1.4 M1.a2 M0 binding mismatch at index #{binding.legacy_index}"
    end
  end

  defp candidate_counts(candidate) do
    rows =
      Enum.reduce(candidate.contributions, 0, fn contribution, count ->
        count +
          Enum.reduce(contribution.callbacks, 0, fn {_callback, values}, n ->
            n + length(values)
          end)
      end)

    %{
      contributions: length(candidate.contributions),
      rows: rows,
      action_bindings: length(candidate.action_bindings),
      aliases: length(candidate.compatibility_aliases),
      compatibility_diagnostics: length(candidate.compatibility_diagnostics)
    }
  end

  defp module_name(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
  end

  defp m0_source_bucket(:native_static), do: "static"
  defp m0_source_bucket(:legacy_plugin), do: "plugin_append"

  defp sha256(bytes) do
    bytes
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp read_source_application!(application) do
    build_lib =
      :allbert_assist
      |> Application.app_dir()
      |> to_string()
      |> Path.dirname()

    path = Path.join([build_lib, Atom.to_string(application), "ebin", "#{application}.app"])
    OTPMetadata.read_app(path) |> value!({:source_app, application})
  end

  defp source_env_fetcher(applications) do
    fn application, :allbert_pack ->
      case Enum.find(applications, &(&1.application == application)) do
        %{pack_module: nil} -> :error
        %{pack_module: module} -> {:ok, module}
      end
    end
  end

  defp value!({:ok, value}, _label), do: value

  defp value!({:error, reason}, label) do
    raise "v1.4 M1.a2 #{label} failed: #{inspect(reason)}"
  end
end
