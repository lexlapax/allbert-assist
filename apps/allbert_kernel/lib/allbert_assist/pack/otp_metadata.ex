defmodule AllbertAssist.Pack.OTPMetadata.ApplicationSpec do
  @moduledoc false

  @enforce_keys [:application, :version, :modules, :applications, :pack_module]
  defstruct @enforce_keys ++
              [
                included_applications: [],
                optional_applications: [],
                raw_spec: nil,
                sha256: nil,
                path: nil
              ]

  @type t :: %__MODULE__{
          application: atom(),
          version: String.t(),
          modules: [module()],
          applications: [atom()],
          included_applications: [atom()],
          optional_applications: [atom()],
          pack_module: module() | nil,
          raw_spec: {:application, atom(), keyword()} | nil,
          sha256: String.t() | nil,
          path: String.t() | nil
        }
end

defmodule AllbertAssist.Pack.OTPMetadata.ReleaseApplication do
  @moduledoc false

  @enforce_keys [:application, :version, :start_mode, :included_applications]
  defstruct @enforce_keys

  @type start_mode :: :permanent | :transient | :temporary | :load | :none
  @type t :: %__MODULE__{
          application: atom(),
          version: String.t(),
          start_mode: start_mode(),
          included_applications: [atom()]
        }
end

defmodule AllbertAssist.Pack.OTPMetadata.ReleaseSpec do
  @moduledoc false

  alias AllbertAssist.Pack.OTPMetadata.ReleaseApplication

  @enforce_keys [:name, :version, :erts_version, :applications]
  defstruct @enforce_keys ++ [sha256: nil, path: nil]

  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t(),
          erts_version: String.t(),
          applications: [ReleaseApplication.t()],
          sha256: String.t() | nil,
          path: String.t() | nil
        }
end

defmodule AllbertAssist.Pack.OTPMetadata do
  @moduledoc """
  Parses trusted OTP application and release records without atomizing strings
  from component manifests.

  Erlang term scanning interns atoms present in the trusted OTP bytes.
  `read_sealed_app/2` therefore verifies the artifact-recorded digest before
  scanning; `read_app/1` and `read_rel/1` are for trusted source/code-path or
  already authenticated release records only.
  """

  alias __MODULE__.ApplicationSpec
  alias __MODULE__.ReleaseApplication
  alias __MODULE__.ReleaseSpec

  @release_start_modes [:permanent, :transient, :temporary, :load, :none]
  @max_metadata_bytes 1_048_576
  @sha256_pattern ~r/\A[0-9a-f]{64}\z/

  @doc "Read a trusted source/code-path application record."
  @spec read_app(Path.t(), keyword()) ::
          {:ok, ApplicationSpec.t()}
          | {:error,
             {:invalid_app_file | :invalid_app, term()}
             | {:app_digest_mismatch, String.t(), String.t()}}
  def read_app(path, opts \\ [])

  def read_app(path, opts) when is_binary(path) and is_list(opts) do
    with {:ok, bytes} <- read_metadata_file(path, :invalid_app_file),
         actual_sha256 = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
         :ok <- verify_expected_app_sha256(actual_sha256, Keyword.get(opts, :expected_sha256)),
         {:ok, term} <- parse_term(bytes, :invalid_app_file) do
      parse_app(term,
        path: Path.expand(path),
        sha256: actual_sha256
      )
    end
  end

  def read_app(_path, _opts), do: {:error, {:invalid_app_file, :path}}

  @doc "Verify a sealed raw application digest before scanning its Erlang term."
  @spec read_sealed_app(Path.t(), String.t()) ::
          {:ok, ApplicationSpec.t()}
          | {:error,
             {:invalid_app_file | :invalid_app, term()}
             | {:app_digest_mismatch, String.t(), String.t()}}
  def read_sealed_app(path, expected_sha256)
      when is_binary(path) and is_binary(expected_sha256) do
    if Regex.match?(@sha256_pattern, expected_sha256),
      do: read_app(path, expected_sha256: expected_sha256),
      else: {:error, {:invalid_app_file, :expected_sha256}}
  end

  def read_sealed_app(_path, _expected_sha256),
    do: {:error, {:invalid_app_file, :expected_sha256}}

  @doc "Read an already authenticated raw release record."
  @spec read_rel(Path.t()) ::
          {:ok, ReleaseSpec.t()} | {:error, {:invalid_rel_file | :invalid_rel, term()}}
  def read_rel(path) when is_binary(path) do
    with {:ok, bytes} <- read_metadata_file(path, :invalid_rel_file),
         {:ok, term} <- parse_term(bytes, :invalid_rel_file) do
      parse_rel(term,
        path: Path.expand(path),
        sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
      )
    end
  end

  def read_rel(_path), do: {:error, {:invalid_rel_file, :path}}

  @spec parse_app(term(), keyword()) ::
          {:ok, ApplicationSpec.t()} | {:error, {:invalid_app, atom()}}
  def parse_app(term, opts \\ [])

  def parse_app({:application, application, properties}, opts)
      when is_list(properties) and is_list(opts) do
    with :ok <- validate_application_identity(application),
         :ok <- validate_properties(properties),
         {:ok, version} <- normalize_version(Keyword.get(properties, :vsn, ~c"")),
         {:ok, modules} <- atom_list(Keyword.get(properties, :modules, []), :modules),
         {:ok, applications} <-
           atom_list(Keyword.get(properties, :applications, []), :applications),
         {:ok, optional_applications} <-
           atom_list(
             Keyword.get(properties, :optional_applications, []),
             :optional_applications
           ),
         {:ok, included_applications} <-
           atom_list(
             Keyword.get(properties, :included_applications, []),
             :included_applications
           ),
         :ok <- validate_optional_applications(optional_applications, applications),
         {:ok, env} <- application_env(Keyword.get(properties, :env, [])),
         {:ok, pack_module} <- pack_module(env, modules) do
      {:ok,
       %ApplicationSpec{
         application: application,
         version: version,
         modules: modules,
         applications: applications,
         optional_applications: optional_applications,
         included_applications: included_applications,
         pack_module: pack_module,
         raw_spec: {:application, application, properties},
         sha256: Keyword.get(opts, :sha256),
         path: Keyword.get(opts, :path)
       }}
    end
  end

  def parse_app(_term, _opts), do: invalid_app(:shape)

  defp validate_application_identity(application) do
    if valid_otp_atom?(application), do: :ok, else: invalid_app(:shape)
  end

  @spec parse_rel(term(), keyword()) ::
          {:ok, ReleaseSpec.t()} | {:error, {:invalid_rel, atom()}}
  def parse_rel(term, opts \\ [])

  def parse_rel({:release, {name, version}, {:erts, erts_version}, applications}, opts)
      when is_list(applications) and is_list(opts) do
    with {:ok, name} <- normalize_rel_string(name, :name),
         {:ok, version} <- normalize_rel_string(version, :version),
         {:ok, erts_version} <- normalize_rel_string(erts_version, :erts_version),
         {:ok, applications} <- parse_release_applications(applications),
         :ok <- unique_release_applications(applications) do
      {:ok,
       %ReleaseSpec{
         name: name,
         version: version,
         erts_version: erts_version,
         applications: applications,
         sha256: Keyword.get(opts, :sha256),
         path: Keyword.get(opts, :path)
       }}
    end
  end

  def parse_rel(_term, _opts), do: invalid_rel(:shape)

  @spec verify_effective_pack(ApplicationSpec.t(), (atom(), atom() ->
                                                      :error | {:ok, term()})) ::
          :ok
          | {:error,
             {:effective_pack_override, atom(), module(), term()}
             | {:missing_effective_pack, atom(), module()}
             | {:unexpected_effective_pack, atom(), term()}}
  def verify_effective_pack(
        %ApplicationSpec{} = application,
        fetcher \\ &Application.fetch_env/2
      )
      when is_function(fetcher, 2) do
    case {application.pack_module, fetcher.(application.application, :allbert_pack)} do
      {nil, :error} ->
        :ok

      {nil, {:ok, actual}} ->
        {:error, {:unexpected_effective_pack, application.application, actual}}

      {expected, {:ok, expected}} ->
        :ok

      {expected, :error} ->
        {:error, {:missing_effective_pack, application.application, expected}}

      {expected, {:ok, actual}} ->
        {:error, {:effective_pack_override, application.application, expected, actual}}

      {_expected, _invalid_fetch_result} ->
        {:error,
         {:effective_pack_override, application.application, application.pack_module, nil}}
    end
  end

  defp validate_properties(properties) do
    if Keyword.keyword?(properties) and unique_keys?(properties),
      do: :ok,
      else: invalid_app(:duplicate_property)
  end

  defp normalize_version(version) when is_binary(version) and byte_size(version) > 0,
    do: {:ok, version}

  defp normalize_version(version) when is_list(version) do
    case List.to_string(version) do
      "" -> invalid_app(:version)
      normalized -> {:ok, normalized}
    end
  rescue
    _error -> invalid_app(:version)
  end

  defp normalize_version(_version), do: invalid_app(:version)

  defp valid_otp_atom?(value), do: is_atom(value) and value not in [nil, true, false]

  defp atom_list(values, _field) when is_list(values) do
    if Enum.all?(values, &valid_otp_atom?/1) and
         MapSet.size(MapSet.new(values)) == length(values),
       do: {:ok, values},
       else: invalid_app(:atom_list)
  end

  defp atom_list(_values, field), do: invalid_app(field)

  defp validate_optional_applications(optional_applications, applications) do
    if MapSet.subset?(MapSet.new(optional_applications), MapSet.new(applications)),
      do: :ok,
      else: invalid_app(:optional_applications_not_subset)
  end

  defp release_atom_list(values) when is_list(values) do
    if Enum.all?(values, &valid_otp_atom?/1) and
         MapSet.size(MapSet.new(values)) == length(values),
       do: {:ok, values},
       else: invalid_rel(:included_applications)
  end

  defp release_atom_list(_values), do: invalid_rel(:included_applications)

  defp application_env(env) when is_list(env) do
    if Keyword.keyword?(env) and unique_keys?(env),
      do: {:ok, env},
      else: invalid_app(:env)
  end

  defp application_env(_env), do: invalid_app(:env)

  defp pack_module(env, modules) do
    case Keyword.fetch(env, :allbert_pack) do
      :error ->
        {:ok, nil}

      {:ok, module} when is_atom(module) and module not in [nil, true, false] ->
        if module in modules, do: {:ok, module}, else: invalid_app(:pack_module_not_owned)

      {:ok, _other} ->
        invalid_app(:pack_module)
    end
  end

  defp unique_keys?(pairs) do
    keys = Enum.map(pairs, &elem(&1, 0))
    MapSet.size(MapSet.new(keys)) == length(keys)
  end

  defp parse_release_applications(applications) do
    Enum.reduce_while(applications, {:ok, []}, fn application, {:ok, parsed} ->
      case parse_release_application(application) do
        {:ok, value} -> {:cont, {:ok, [value | parsed]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp parse_release_application({application, version}) do
    build_release_application(application, version, :permanent, [])
  end

  defp parse_release_application({application, version, start_mode})
       when is_atom(start_mode) do
    build_release_application(application, version, start_mode, [])
  end

  defp parse_release_application({application, version, included_applications})
       when is_list(included_applications) do
    build_release_application(application, version, :permanent, included_applications)
  end

  defp parse_release_application({application, version, start_mode, included_applications}) do
    build_release_application(application, version, start_mode, included_applications)
  end

  defp parse_release_application(_application), do: invalid_rel(:application_tuple)

  defp build_release_application(application, version, start_mode, included_applications)
       when start_mode in @release_start_modes do
    with :ok <- validate_release_application_identity(application),
         {:ok, version} <- normalize_rel_string(version, :application_version),
         {:ok, included_applications} <- release_atom_list(included_applications) do
      {:ok,
       %ReleaseApplication{
         application: application,
         version: version,
         start_mode: start_mode,
         included_applications: included_applications
       }}
    end
  end

  defp build_release_application(_application, _version, _start_mode, _included),
    do: invalid_rel(:application_tuple)

  defp validate_release_application_identity(application) do
    if valid_otp_atom?(application), do: :ok, else: invalid_rel(:application_tuple)
  end

  defp unique_release_applications(applications) do
    names = Enum.map(applications, & &1.application)

    if MapSet.size(MapSet.new(names)) == length(names),
      do: :ok,
      else: invalid_rel(:duplicate_application)
  end

  defp normalize_rel_string(value, _field) when is_binary(value) and byte_size(value) > 0,
    do: {:ok, value}

  defp normalize_rel_string(value, field) when is_list(value) do
    case List.to_string(value) do
      "" -> invalid_rel(field)
      normalized -> {:ok, normalized}
    end
  rescue
    _error -> invalid_rel(field)
  end

  defp normalize_rel_string(_value, field), do: invalid_rel(field)

  defp read_metadata_file(path, error_tag) do
    with {:ok, %{type: :regular, size: size}} when size <= @max_metadata_bytes <-
           File.lstat(path),
         {:ok, bytes} when byte_size(bytes) <= @max_metadata_bytes <- File.read(path) do
      {:ok, bytes}
    else
      {:ok, bytes} when is_binary(bytes) ->
        {:error, {error_tag, {:too_large, byte_size(bytes)}}}

      {:ok, %{type: :regular, size: size}} ->
        {:error, {error_tag, {:too_large, size}}}

      {:ok, %{type: type}} ->
        {:error, {error_tag, {:not_regular, type}}}

      {:error, reason} ->
        {:error, {error_tag, reason}}
    end
  end

  defp parse_term(bytes, error_tag) do
    with {:ok, tokens, _end_location} <- :erl_scan.string(String.to_charlist(bytes)),
         {:ok, term} <- :erl_parse.parse_term(tokens) do
      {:ok, term}
    else
      {:error, reason, _location} -> {:error, {error_tag, reason}}
      {:error, reason} -> {:error, {error_tag, reason}}
    end
  rescue
    _error -> {:error, {error_tag, :invalid_encoding}}
  end

  defp verify_expected_app_sha256(_actual, nil), do: :ok
  defp verify_expected_app_sha256(expected, expected), do: :ok

  defp verify_expected_app_sha256(actual, expected) when is_binary(expected),
    do: {:error, {:app_digest_mismatch, expected, actual}}

  defp verify_expected_app_sha256(_actual, _expected),
    do: {:error, {:invalid_app_file, :expected_sha256}}

  defp invalid_app(reason), do: {:error, {:invalid_app, reason}}
  defp invalid_rel(reason), do: {:error, {:invalid_rel, reason}}
end
