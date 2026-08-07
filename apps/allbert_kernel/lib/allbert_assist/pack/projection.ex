defmodule AllbertAssist.Pack.Projection.Row do
  @moduledoc false

  alias AllbertAssist.Pack.Descriptor

  @enforce_keys [
    :schema_version,
    :component,
    :application,
    :application_version,
    :id,
    :descriptor_module,
    :startup_role,
    :registry_order,
    :app_sha256,
    :descriptor
  ]
  defstruct @enforce_keys

  @type startup_role :: :kernel_prerequisite | :native_passive | :native_effectful
  @type t :: %__MODULE__{
          schema_version: 1,
          component: String.t(),
          application: atom(),
          application_version: String.t(),
          id: String.t(),
          descriptor_module: module(),
          startup_role: startup_role(),
          registry_order: non_neg_integer(),
          app_sha256: String.t() | nil,
          descriptor: Descriptor.t()
        }
end

defmodule AllbertAssist.Pack.Projection do
  @moduledoc """
  Reconciles the component Pack index with trusted OTP and descriptor records.

  Catalog strings are comparison data only. Application and module atoms always
  originate in consulted OTP terms.
  """

  alias __MODULE__.Row
  alias AllbertAssist.Pack.{Descriptor, Identity, OTPMetadata}
  alias AllbertAssist.Pack.OTPMetadata.{ApplicationSpec, ReleaseApplication, ReleaseSpec}

  @source_pack_keys ~w(descriptor_module id registry_order schema_version startup_role)
  @sealed_pack_keys Enum.sort(["app_sha256" | @source_pack_keys])
  @module_pattern ~r/\AElixir\.[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*\z/
  @sha256_pattern ~r/\A[0-9a-f]{64}\z/
  @row_keys Enum.sort([
              :__struct__,
              :schema_version,
              :component,
              :application,
              :application_version,
              :id,
              :descriptor_module,
              :startup_role,
              :registry_order,
              :app_sha256,
              :descriptor
            ])

  @type reason :: {:invalid_projection, term()}

  @spec reconcile([map()], [ApplicationSpec.t()], ReleaseSpec.t(), keyword()) ::
          {:ok, [Row.t()]} | {:error, reason()}
  def reconcile(component_rows, applications, release, opts \\ [])

  def reconcile(component_rows, applications, %ReleaseSpec{} = release, opts)
      when is_list(component_rows) and is_list(applications) and is_list(opts) do
    sealed? = Keyword.get(opts, :sealed, false)
    descriptor_fetcher = Keyword.get(opts, :descriptor_fetcher, &fetch_descriptor/1)

    effective_env_fetcher =
      Keyword.get(opts, :effective_env_fetcher, &Application.fetch_env/2)

    with {:ok, closed_applications} <- closed_applications(opts),
         {:ok, application_index} <-
           index_unique(applications, &Atom.to_string(&1.application), :duplicate_application),
         {:ok, release_index} <-
           index_unique(release.applications, & &1.application, :duplicate_release_application),
         :ok <-
           validate_closed_application_scope(
             closed_applications,
             applications,
             release.applications,
             release_index
           ),
         {:ok, pack_component_rows} <- pack_component_rows(component_rows),
         {:ok, rows} <-
           reconcile_rows(
             pack_component_rows,
             application_index,
             release_index,
             descriptor_fetcher,
             effective_env_fetcher,
             sealed?
           ),
         :ok <- exact_descriptor_closure(rows, applications),
         :ok <- validate_uniqueness(rows) do
      {:ok, Enum.sort_by(rows, &{&1.registry_order, Atom.to_string(&1.application)})}
    end
  end

  def reconcile(_component_rows, _applications, _release, _opts),
    do: invalid(:shape)

  @spec canonical_bytes([Row.t()]) :: {:ok, binary()} | {:error, reason()}
  def canonical_bytes(rows) when is_list(rows) do
    with :ok <- validate_uniqueness(rows),
         {:ok, encoded} <- encode_canonical_rows(rows) do
      {:ok, IO.iodata_to_binary(["[", Enum.intersperse(encoded, ","), "]"])}
    end
  rescue
    _error -> invalid(:canonical_rows)
  end

  def canonical_bytes(_rows), do: invalid(:canonical_rows)

  @spec digest([Row.t()]) :: {:ok, String.t()} | {:error, reason()}
  def digest(rows) do
    with {:ok, bytes} <- canonical_bytes(rows) do
      {:ok, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
    end
  end

  defp encode_canonical_rows(rows) do
    rows
    |> Enum.sort_by(&{&1.registry_order, Atom.to_string(&1.application)})
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, encoded} ->
      case encode_canonical_row(row) do
        {:ok, bytes} -> {:cont, {:ok, [bytes | encoded]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, encoded} -> {:ok, Enum.reverse(encoded)}
      error -> error
    end
  end

  defp reconcile_rows(
         rows,
         application_index,
         release_index,
         descriptor_fetcher,
         effective_env_fetcher,
         sealed?
       ) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, reconciled} ->
      case reconcile_row(
             row,
             application_index,
             release_index,
             descriptor_fetcher,
             effective_env_fetcher,
             sealed?
           ) do
        {:ok, value} -> {:cont, {:ok, [value | reconciled]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reconciled} -> {:ok, Enum.reverse(reconciled)}
      error -> error
    end
  end

  defp closed_applications(opts) do
    case Keyword.fetch(opts, :closed_applications) do
      :error ->
        invalid(:closed_applications_required)

      {:ok, applications} when is_list(applications) ->
        valid? =
          Enum.all?(applications, &valid_application_atom?/1) and
            MapSet.size(MapSet.new(applications)) == length(applications)

        if valid?, do: {:ok, applications}, else: invalid(:closed_applications)

      {:ok, _applications} ->
        invalid(:closed_applications)
    end
  end

  defp validate_closed_application_scope(
         closed_applications,
         applications,
         release_applications,
         release_index
       ) do
    application_names = Enum.map(applications, & &1.application)
    closed_set = MapSet.new(closed_applications)

    release_names =
      release_applications
      |> Enum.map(& &1.application)
      |> Enum.filter(&MapSet.member?(closed_set, &1))

    cond do
      application_names != closed_applications ->
        invalid({:application_closure, closed_applications, application_names})

      release_names != closed_applications ->
        invalid({:release_application_closure, closed_applications, release_names})

      true ->
        validate_closed_application_records(applications, release_index)
    end
  end

  defp validate_closed_application_records(applications, release_index) do
    Enum.reduce_while(applications, :ok, fn application, :ok ->
      result =
        with {:ok, release_application} <-
               fetch_index(
                 release_index,
                 application.application,
                 {:missing_release_application, application.application}
               ) do
          validate_release_application(application, release_application)
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp pack_component_rows(component_rows) do
    Enum.reduce_while(component_rows, {:ok, []}, fn
      component, {:ok, rows} when is_map(component) ->
        case Map.fetch(component, "pack") do
          :error -> {:cont, {:ok, rows}}
          {:ok, pack} when is_map(pack) -> {:cont, {:ok, [component | rows]}}
          {:ok, _pack} -> {:halt, invalid(:pack_shape)}
        end

      _component, _rows ->
        {:halt, invalid(:component_shape)}
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp reconcile_row(
         %{"id" => component, "application" => application_name, "pack" => pack},
         application_index,
         release_index,
         descriptor_fetcher,
         effective_env_fetcher,
         sealed?
       )
       when is_binary(component) and byte_size(component) > 0 and is_binary(application_name) and
              is_map(pack) do
    with {:ok, component} <- valid_component(component),
         {:ok, application_name} <- valid_application_name(application_name),
         :ok <- validate_pack_shape(pack, sealed?),
         {:ok, id} <- valid_id(pack["id"]),
         {:ok, descriptor_module_name} <- valid_module_name(pack["descriptor_module"]),
         {:ok, startup_role} <- normalize_role(pack["startup_role"]),
         {:ok, registry_order} <- valid_order(pack["registry_order"]),
         {:ok, app_sha256} <- valid_app_sha256(pack, sealed?),
         {:ok, %ApplicationSpec{} = application} <-
           fetch_index(
             application_index,
             application_name,
             {:unknown_application, application_name}
           ),
         :ok <- compare_module_name(application, descriptor_module_name),
         :ok <- verify_effective_env(application, effective_env_fetcher),
         {:ok, %ReleaseApplication{} = release_application} <-
           fetch_index(
             release_index,
             application.application,
             {:missing_release_application, application.application}
           ),
         :ok <- validate_release_application(application, release_application),
         {:ok, descriptor} <- descriptor_fetcher.(application.pack_module),
         {:ok, descriptor} <- Descriptor.validate(descriptor),
         :ok <-
           validate_descriptor(
             descriptor,
             application,
             component,
             id,
             startup_role,
             registry_order
           ),
         :ok <- compare_app_sha256(application, app_sha256, sealed?) do
      {:ok,
       %Row{
         schema_version: 1,
         component: component,
         application: application.application,
         application_version: application.version,
         id: id,
         descriptor_module: application.pack_module,
         startup_role: startup_role,
         registry_order: registry_order,
         app_sha256: app_sha256,
         descriptor: descriptor
       }}
    else
      {:error, {:invalid_descriptor, field}} -> invalid({:descriptor, field})
      {:error, {:invalid_projection, _reason}} = error -> error
      {:error, reason} -> invalid(reason)
      other -> invalid({:unexpected_result, other})
    end
  rescue
    _error -> invalid(:descriptor_callback)
  end

  defp reconcile_row(_row, _applications, _release, _fetcher, _env_fetcher, _sealed?),
    do: invalid(:component_shape)

  defp validate_pack_shape(pack, sealed?) do
    expected = if sealed?, do: @sealed_pack_keys, else: @source_pack_keys

    if Enum.sort(Map.keys(pack)) == expected and pack["schema_version"] == 1,
      do: :ok,
      else: invalid(:pack_shape)
  end

  defp valid_id(id) when is_binary(id) and byte_size(id) in 1..64 do
    if Identity.canonical_id?(id), do: {:ok, id}, else: invalid(:id)
  end

  defp valid_id(_id), do: invalid(:id)

  defp valid_application_atom?(application),
    do: Identity.canonical_application?(application)

  defp valid_application_name(name) do
    if Identity.canonical_id?(name), do: {:ok, name}, else: invalid(:application)
  end

  defp valid_component(component)
       when is_binary(component) and byte_size(component) in 1..255 do
    if Identity.canonical_component?(component),
      do: {:ok, component},
      else: invalid(:component)
  end

  defp valid_component(_component), do: invalid(:component)

  defp valid_module_name(name) when is_binary(name) and byte_size(name) in 1..255 do
    if Regex.match?(@module_pattern, name), do: {:ok, name}, else: invalid(:descriptor_module)
  end

  defp valid_module_name(_name), do: invalid(:descriptor_module)

  defp normalize_role("kernel_prerequisite"), do: {:ok, :kernel_prerequisite}
  defp normalize_role("native_passive"), do: {:ok, :native_passive}
  defp normalize_role("native_effectful"), do: {:ok, :native_effectful}
  defp normalize_role(_role), do: invalid(:startup_role)

  defp role_name(:kernel_prerequisite), do: {:ok, "kernel_prerequisite"}
  defp role_name(:native_passive), do: {:ok, "native_passive"}
  defp role_name(:native_effectful), do: {:ok, "native_effectful"}
  defp role_name(_role), do: invalid(:startup_role)

  defp valid_order(order) when is_integer(order) and order >= 0, do: {:ok, order}
  defp valid_order(_order), do: invalid(:registry_order)

  defp valid_app_sha256(_pack, false), do: {:ok, nil}

  defp valid_app_sha256(%{"app_sha256" => sha256}, true) when is_binary(sha256) do
    if Regex.match?(@sha256_pattern, sha256), do: {:ok, sha256}, else: invalid(:app_sha256)
  end

  defp valid_app_sha256(_pack, true), do: invalid(:app_sha256)

  defp compare_module_name(%ApplicationSpec{pack_module: nil} = application, _name),
    do: invalid({:missing_raw_pack_module, application.application})

  defp compare_module_name(%ApplicationSpec{pack_module: module}, name) do
    if Atom.to_string(module) == name,
      do: :ok,
      else: invalid({:descriptor_module_mismatch, Atom.to_string(module), name})
  end

  defp verify_effective_env(application, fetcher) when is_function(fetcher, 2),
    do: OTPMetadata.verify_effective_pack(application, fetcher)

  defp verify_effective_env(_application, _fetcher), do: invalid(:effective_env_fetcher)

  defp validate_release_application(application, release_application) do
    cond do
      application.included_applications != [] ->
        invalid({:raw_included_applications, application.application})

      release_application.included_applications != [] ->
        invalid({:release_included_applications, application.application})

      release_application.version != application.version ->
        invalid({:release_version_mismatch, application.application})

      release_application.start_mode != :permanent ->
        invalid({:non_permanent_pack, application.application})

      true ->
        :ok
    end
  end

  defp validate_descriptor(
         descriptor,
         application,
         component,
         id,
         startup_role,
         registry_order
       ) do
    with {:ok, expected_tier} <- capability_tier_for_role(startup_role),
         :ok <-
           require_equal(descriptor.application, application.application, :descriptor_application),
         :ok <-
           require_equal(
             descriptor.application_version,
             application.version,
             :descriptor_version
           ),
         :ok <- require_equal(descriptor.id, id, :descriptor_id),
         :ok <- require_equal(descriptor.registry_order, registry_order, :descriptor_order),
         :ok <- require_equal(descriptor.capability_tier, expected_tier, :descriptor_tier) do
      require_equal(
        descriptor.provenance,
        %{source: :signed_release, component: component},
        :descriptor_provenance
      )
    end
  end

  defp require_equal(value, value, _reason), do: :ok
  defp require_equal(_actual, _expected, reason), do: invalid(reason)

  defp compare_app_sha256(_application, _sha256, false), do: :ok

  defp compare_app_sha256(%ApplicationSpec{sha256: sha256}, sha256, true), do: :ok

  defp compare_app_sha256(application, _sha256, true),
    do: invalid({:app_sha256_mismatch, application.application})

  defp encode_canonical_row(%Row{} = row) do
    with true <- Enum.sort(Map.keys(row)) == @row_keys,
         :ok <- validate_row_descriptor(row),
         application = Atom.to_string(row.application),
         descriptor_module = Atom.to_string(row.descriptor_module),
         true <- row.schema_version == 1,
         {:ok, _component} <- valid_component(row.component),
         {:ok, _application} <- valid_id(application),
         {:ok, _id} <- valid_id(row.id),
         {:ok, _module} <- valid_module_name(descriptor_module),
         {:ok, startup_role} <- role_name(row.startup_role),
         {:ok, registry_order} <- valid_order(row.registry_order),
         true <- is_binary(row.app_sha256) and Regex.match?(@sha256_pattern, row.app_sha256) do
      {:ok,
       IO.iodata_to_binary([
         ~s({"app_sha256":"),
         row.app_sha256,
         ~s(","application":"),
         application,
         ~s(","component":"),
         row.component,
         ~s(","descriptor_module":"),
         descriptor_module,
         ~s(","id":"),
         row.id,
         ~s(","registry_order":),
         Integer.to_string(registry_order),
         ~s(,"schema_version":1,"startup_role":"),
         startup_role,
         ~s("})
       ])}
    else
      {:error, {:invalid_projection, _reason}} = error -> error
      _other -> invalid(:canonical_row)
    end
  end

  defp encode_canonical_row(_row), do: invalid(:canonical_row)

  defp validate_row_descriptor(%Row{descriptor: descriptor} = row) do
    with {:ok, expected_tier} <- capability_tier_for_role(row.startup_role),
         {:ok, ^descriptor} <- Descriptor.validate(descriptor),
         :ok <- require_equal(descriptor.schema_version, row.schema_version, :descriptor_schema),
         :ok <- require_equal(descriptor.application, row.application, :descriptor_application),
         :ok <-
           require_equal(
             descriptor.application_version,
             row.application_version,
             :descriptor_version
           ),
         :ok <- require_equal(descriptor.id, row.id, :descriptor_id),
         :ok <- require_equal(descriptor.registry_order, row.registry_order, :descriptor_order),
         :ok <- require_equal(descriptor.capability_tier, expected_tier, :descriptor_tier) do
      require_equal(
        descriptor.provenance,
        %{source: :signed_release, component: row.component},
        :descriptor_provenance
      )
    else
      {:error, {:invalid_descriptor, field}} -> invalid({:descriptor, field})
      {:error, {:invalid_projection, _reason}} = error -> error
    end
  end

  defp capability_tier_for_role(:kernel_prerequisite), do: {:ok, :kernel}

  defp capability_tier_for_role(role) when role in [:native_passive, :native_effectful],
    do: {:ok, :native}

  defp capability_tier_for_role(_role), do: invalid(:startup_role)

  defp exact_descriptor_closure(rows, applications) do
    expected =
      applications
      |> Enum.reject(&is_nil(&1.pack_module))
      |> Enum.map(& &1.application)
      |> MapSet.new()

    actual = rows |> Enum.map(& &1.application) |> MapSet.new()

    if expected == actual,
      do: :ok,
      else: invalid({:descriptor_closure, MapSet.to_list(expected), MapSet.to_list(actual)})
  end

  defp validate_uniqueness(rows) do
    for {field, key} <- [
          application: & &1.application,
          id: & &1.id,
          descriptor_module: & &1.descriptor_module,
          registry_order: & &1.registry_order
        ],
        duplicate?(rows, key),
        reduce: :ok do
      :ok -> invalid({:duplicate, field})
      error -> error
    end
  end

  defp duplicate?(rows, key) do
    values = Enum.map(rows, key)
    MapSet.size(MapSet.new(values)) != length(values)
  end

  defp index_unique(values, key, reason) do
    index = Map.new(values, &{key.(&1), &1})
    if map_size(index) == length(values), do: {:ok, index}, else: invalid(reason)
  end

  defp fetch_index(index, key, reason) do
    case Map.fetch(index, key) do
      {:ok, value} -> {:ok, value}
      :error -> invalid(reason)
    end
  end

  defp fetch_descriptor(nil), do: invalid(:missing_descriptor_module)

  defp fetch_descriptor(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :descriptor, 0),
      do: {:ok, apply(module, :descriptor, [])},
      else: invalid({:missing_descriptor_callback, module})
  end

  defp invalid(reason), do: {:error, {:invalid_projection, reason}}
end
