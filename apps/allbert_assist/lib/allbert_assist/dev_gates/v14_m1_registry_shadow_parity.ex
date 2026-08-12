defmodule AllbertAssist.DevGates.V14M1RegistryShadowParity do
  @moduledoc """
  Deterministic evidence helpers for the v1.4 M1.a2 shadow Pack checkpoint.

  This module owns generated test fixtures and frozen-ledger comparison.
  """

  alias AllbertAssist.DevGates.V14M0RegistryLedger
  alias AllbertAssist.Licenses
  alias AllbertAssist.Objectives.CanonicalJSON

  alias AllbertAssist.Pack.{
    OTPMetadata,
    Projection,
    RowSchemas
  }

  alias AllbertAssist.Pack.OTPMetadata.{ReleaseApplication, ReleaseSpec}
  alias AllbertAssist.Pack.Registry.Candidate

  @schema_version 1
  @normalization "v14_pack_row_schema_contract_v1"
  @row_schema_contract_domain "allbert.pack.row-schema-contract.v1\0"
  @repo_root Path.expand("../../../../..", __DIR__)
  # Mirrors ProjectionProvider's list, in R0 frozen DAG order: kernel, residual,
  # each extracted pack, the composition host, then Web. v1.4 M9 added
  # :allbert_notes_files. A pack missing here seals without its app_sha256 and
  # the projection is rejected with :pack_shape.
  @closed_applications [
    :allbert_kernel,
    :allbert_assist,
    :allbert_notes_files,
    :allbert_telegram,
    :allbert_email,
    :allbert_research,
    :allbert_browser,
    :allbert_composition,
    :allbert_assist_web
  ]

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

  @doc """
  Build the sealed source projection used by the M1.a2 shadow gate.

  Accepts a narrower application set than the full closure. A caller that
  constructs a deliberately minimal candidate cannot satisfy a projection
  carrying every pack -- v1.4 M9's extraction made that concrete -- and needs to
  close over only the applications its fixture supports. Pack components outside
  the requested set are dropped; third-party component rows are untouched,
  because they belong to the catalog rather than to the closure.
  """
  @spec source_closed_projection!([atom()]) :: Projection.Closed.t()
  def source_closed_projection!(closed_applications \\ @closed_applications) do
    catalog = Licenses.load_catalog(repo_root: @repo_root) |> value!(:source_catalog)
    applications = Enum.map(closed_applications, &read_source_application!/1)
    application_index = Map.new(applications, &{Atom.to_string(&1.application), &1})

    in_closure? = MapSet.new(closed_applications, &Atom.to_string/1)

    components =
      catalog
      |> Map.fetch!("components")
      |> Enum.reject(fn component ->
        is_map(component["pack"]) and not MapSet.member?(in_closure?, component["application"])
      end)
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
      closed_applications: closed_applications,
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
             Enum.map(bindings, & &1.legacy_index) == expected_indices and
             Enum.map(bindings, & &1.registry_order) == expected_indices do
      raise "v1.4 M1.a2 prepared M0 payload or binding indices are not exact"
    end

    Enum.zip(bindings, rows)
    |> Enum.each(fn {binding, row} -> verify_m0_binding!(binding, row) end)

    :ok
  end

  def verify_m0_bindings!(_candidate, _prepared) do
    raise "invalid v1.4 M1.a2 prepared M0 binding evidence"
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

  defp module_name(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
  end

  defp m0_source_bucket(:native_static), do: "static"
  defp m0_source_bucket(:legacy_plugin), do: "plugin_append"

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
