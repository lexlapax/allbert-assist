defmodule AllbertAssist.Resources.Ref do
  @moduledoc """
  Shared local/remote resource reference contract.

  Resource references are inert plain data. They describe resource identity,
  scope, operation class, access mode, limits, and downstream consumer for
  confirmations and future approval handoff. They never authorize or execute.
  """

  alias AllbertAssist.Resources.OperationClass
  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Resources.Scope

  @enforce_keys [
    :resource_uri,
    :origin_kind,
    :canonical_id,
    :operation_class,
    :access_mode,
    :scope
  ]
  defstruct [
    :resource_uri,
    :origin_kind,
    :canonical_id,
    :operation_class,
    :access_mode,
    :scope,
    :downstream_consumer,
    :source_profile,
    :method,
    :digest,
    :display_uri,
    unsupported?: false,
    limits: %{},
    redaction: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          resource_uri: String.t(),
          origin_kind: atom(),
          canonical_id: String.t(),
          operation_class: atom(),
          access_mode: atom(),
          scope: Scope.t(),
          downstream_consumer: atom() | String.t() | nil,
          source_profile: String.t() | nil,
          method: String.t() | nil,
          digest: String.t() | nil,
          display_uri: String.t() | nil,
          unsupported?: boolean(),
          limits: map(),
          redaction: map(),
          metadata: map()
        }

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    operation_class = field(attrs, :operation_class)

    with {:ok, resource_uri} <-
           ResourceURI.normalize(field(attrs, :resource_uri) || field(attrs, :uri)),
         {:ok, derived} <- ResourceURI.derived_fields(resource_uri),
         {:ok, origin_kind} <- origin_kind(attrs, derived.origin_kind),
         {:ok, operation_class} <- OperationClass.operation_class(operation_class),
         {:ok, access_mode} <- access_mode(attrs, operation_class),
         {:ok, canonical_id} <- canonical_id(attrs, derived.canonical_id),
         {:ok, scope} <- normalize_scope(field(attrs, :scope)) do
      {:ok,
       %__MODULE__{
         resource_uri: resource_uri,
         origin_kind: origin_kind,
         canonical_id: canonical_id,
         operation_class: operation_class,
         access_mode: access_mode,
         scope: scope,
         downstream_consumer: field(attrs, :downstream_consumer),
         source_profile: normalize_optional_string(field(attrs, :source_profile)),
         method: normalize_optional_string(field(attrs, :method)),
         digest: normalize_optional_string(field(attrs, :digest)),
         display_uri: normalize_optional_string(field(attrs, :display_uri)),
         unsupported?: derived.unsupported?,
         limits: normalize_map(field(attrs, :limits)),
         redaction: normalize_map(field(attrs, :redaction)),
         metadata: normalize_map(field(attrs, :metadata))
       }}
    end
  end

  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, ref} -> ref
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = ref) do
    %{
      resource_uri: ref.resource_uri,
      origin_kind: ref.origin_kind,
      canonical_id: ref.canonical_id,
      operation_class: ref.operation_class,
      access_mode: ref.access_mode,
      scope: Scope.to_map(ref.scope),
      downstream_consumer: ref.downstream_consumer,
      source_profile: ref.source_profile,
      method: ref.method,
      digest: ref.digest,
      display_uri: ref.display_uri,
      unsupported?: ref.unsupported?,
      limits: ref.limits,
      redaction: ref.redaction,
      metadata: ref.metadata
    }
    |> drop_empty_values()
  end

  @spec to_maps([t() | map()]) :: [map()]
  def to_maps(refs) when is_list(refs) do
    Enum.map(refs, fn
      %__MODULE__{} = ref -> to_map(ref)
      ref when is_map(ref) -> ref
    end)
  end

  @spec from_shell_command_summary(map()) :: [map()]
  def from_shell_command_summary(summary) when is_map(summary) do
    cwd_ref =
      summary
      |> field(:resolved_cwd)
      |> case do
        nil ->
          []

        cwd ->
          [
            new!(%{
              resource_uri: ResourceURI.file!(cwd),
              origin_kind: :local_path,
              canonical_id: cwd,
              operation_class: :run_shell_command,
              scope: Scope.directory_subtree(cwd),
              downstream_consumer: :shell_runner,
              limits: limits(summary, [:timeout_ms, :max_output_bytes]),
              metadata: %{
                executable: field(summary, :executable),
                command_class: field(summary, :command_class),
                command_profile: field(summary, :command_profile),
                sandbox_level: field(summary, :sandbox_level)
              }
            })
          ]
      end

    operand_refs =
      summary
      |> field(:path_operands, [])
      |> Enum.map(fn operand ->
        resolved = field(operand, :resolved)

        new!(%{
          resource_uri: ResourceURI.file!(resolved),
          origin_kind: :local_path,
          canonical_id: resolved,
          operation_class: :read_local_path,
          access_mode: :read,
          scope: Scope.exact_file(resolved),
          downstream_consumer: :shell_runner,
          metadata: %{
            original: field(operand, :original),
            allowed?: field(operand, :allowed?)
          }
        })
      end)

    to_maps(cwd_ref ++ operand_refs)
  end

  def from_shell_command_summary(_summary), do: []

  @spec from_skill_script_summary(map()) :: [map()]
  def from_skill_script_summary(summary) when is_map(summary) do
    skill_name = field(summary, :skill_name)
    script_path = field(summary, :script_path)
    script_id = Enum.join(Enum.reject([skill_name, script_path], &blank?/1), ":")

    script_ref =
      if blank?(script_id) do
        []
      else
        [
          new!(%{
            resource_uri: ResourceURI.skill_resource!(script_id),
            origin_kind: :local_skill_resource,
            canonical_id: script_id,
            operation_class: :run_skill_script,
            scope: Scope.skill_resource_id(script_id),
            downstream_consumer: :skill_script_runner,
            digest: field(summary, :script_sha256),
            limits: limits(summary, [:timeout_ms, :max_output_bytes]),
            metadata: %{
              skill_name: skill_name,
              script_path: script_path,
              resolved_executable: field(summary, :resolved_executable),
              byte_size: field(summary, :byte_size),
              sandbox_level: field(summary, :sandbox_level)
            }
          })
        ]
      end

    cwd_ref =
      summary
      |> field(:resolved_cwd)
      |> case do
        nil ->
          []

        cwd ->
          [
            new!(%{
              resource_uri: ResourceURI.file!(cwd),
              origin_kind: :local_path,
              canonical_id: cwd,
              operation_class: :run_skill_script,
              access_mode: :execute,
              scope: Scope.directory_subtree(cwd),
              downstream_consumer: :skill_script_runner,
              metadata: %{cwd_source: field(summary, :cwd_source)}
            })
          ]
      end

    to_maps(script_ref ++ cwd_ref)
  end

  def from_skill_script_summary(_summary), do: []

  @spec from_external_request_summary(map()) :: [map()]
  def from_external_request_summary(summary) when is_map(summary) do
    canonical_url = field(summary, :canonical_url) || field(summary, :url)
    display_url = field(summary, :display_url) || field(summary, :url) || canonical_url

    if blank?(canonical_url) do
      []
    else
      [
        new!(%{
          resource_uri: ResourceURI.url!(canonical_url),
          origin_kind: :remote_url,
          canonical_id: canonical_url,
          operation_class: :external_service_request,
          scope: Scope.exact_url(canonical_url),
          source_profile: field(summary, :profile),
          method: field(summary, :method),
          downstream_consumer: :req_http,
          digest: field(summary, :request_digest),
          display_uri: display_url,
          limits: limits(summary, [:timeout_ms, :max_response_bytes]),
          redaction: %{
            query?: field(summary, :query?),
            request_headers: :redacted_by_policy,
            body: :summarized
          },
          metadata: %{
            display_url: display_url,
            host: field(summary, :host),
            path: field(summary, :path),
            allow_redirects?: field(summary, :allow_redirects?),
            max_redirects: field(summary, :max_redirects),
            retry_policy: field(summary, :retry_policy)
          }
        })
      ]
      |> to_maps()
    end
  end

  def from_external_request_summary(_summary), do: []

  @spec from_package_install_summary(map()) :: [map()]
  def from_package_install_summary(summary) when is_map(summary) do
    manager = field(summary, :manager)

    package_refs =
      summary
      |> field(:packages, [])
      |> Enum.map(fn package ->
        package_id = "#{manager}:#{package}"

        new!(%{
          resource_uri: ResourceURI.package!(manager, package),
          origin_kind: :package_registry,
          canonical_id: package_id,
          operation_class: :package_install,
          scope: Scope.source_profile(manager || "unknown"),
          downstream_consumer: :package_manager,
          source_profile: manager,
          limits: limits(summary, [:timeout_ms, :max_output_bytes]),
          metadata: %{package: package, save_mode: field(summary, :save_mode)}
        })
      end)

    target_root_ref =
      summary
      |> field(:resolved_target_root)
      |> case do
        nil ->
          []

        target_root ->
          [
            new!(%{
              resource_uri: ResourceURI.file!(target_root),
              origin_kind: :local_path,
              canonical_id: target_root,
              operation_class: :package_install,
              access_mode: :write,
              scope: Scope.package_target_root(target_root),
              downstream_consumer: :package_manager,
              source_profile: manager,
              metadata: %{target_root: field(summary, :target_root)}
            })
          ]
      end

    to_maps(package_refs ++ target_root_ref)
  end

  def from_package_install_summary(_summary), do: []

  @spec online_skill_source(map(), atom(), map()) :: [map()]
  def online_skill_source(source_summary, operation_class, metadata \\ %{})

  def online_skill_source(source_summary, operation_class, metadata)
      when is_map(source_summary) do
    source_id = field(source_summary, :id)

    if blank?(source_id) do
      []
    else
      [
        new!(%{
          resource_uri: ResourceURI.source_profile!(:online_skill, source_id),
          origin_kind: :remote_source,
          canonical_id: source_id,
          operation_class: operation_class,
          scope: Scope.source_profile(source_id),
          source_profile: source_id,
          downstream_consumer: :online_skill_registry,
          limits: limits(source_summary, [:max_listing_results, :max_download_bytes]),
          metadata:
            Map.merge(
              %{
                base_url: field(source_summary, :base_url),
                api_url: field(source_summary, :api_url)
              },
              metadata
            )
        })
      ]
      |> to_maps()
    end
  end

  def online_skill_source(_source_summary, _operation_class, _metadata), do: []

  @spec local_skill_import(term(), map()) :: map()
  def local_skill_import(path, metadata \\ %{}) do
    canonical = Path.expand(to_string(path))

    new!(%{
      resource_uri: ResourceURI.file!(canonical),
      origin_kind: :local_path,
      canonical_id: canonical,
      operation_class: :import_local_skill,
      scope: Scope.directory_subtree(canonical),
      downstream_consumer: :skill_importer,
      metadata: metadata
    })
    |> to_map()
  end

  @spec remote_skill_import(term(), map()) :: map()
  def remote_skill_import(url, metadata \\ %{}) do
    url = to_string(url)

    new!(%{
      resource_uri: ResourceURI.url!(url),
      origin_kind: :remote_url,
      canonical_id: url,
      operation_class: :import_skill,
      scope: Scope.exact_url(url),
      downstream_consumer: :skill_importer,
      metadata: metadata
    })
    |> to_map()
  end

  defp access_mode(attrs, operation_class) do
    attrs
    |> field(:access_mode)
    |> case do
      nil -> {:ok, OperationClass.default_access_mode(operation_class)}
      value -> OperationClass.access_mode(value)
    end
  end

  defp origin_kind(attrs, derived_origin_kind) do
    case field(attrs, :origin_kind) do
      nil -> {:ok, derived_origin_kind}
      value -> value |> OperationClass.origin_kind() |> validate_origin_kind(derived_origin_kind)
    end
  end

  defp validate_origin_kind({:ok, origin_kind}, origin_kind), do: {:ok, origin_kind}

  defp validate_origin_kind({:ok, origin_kind}, derived_origin_kind),
    do: {:error, {:resource_uri_origin_kind_mismatch, origin_kind, derived_origin_kind}}

  defp validate_origin_kind({:error, reason}, _derived_origin_kind), do: {:error, reason}

  defp canonical_id(_attrs, derived_canonical_id), do: {:ok, derived_canonical_id}

  defp normalize_scope(%Scope{} = scope), do: {:ok, scope}

  defp normalize_scope(%{kind: kind, value: value}), do: Scope.new(kind, value)
  defp normalize_scope(%{"kind" => kind, "value" => value}), do: Scope.new(kind, value)
  defp normalize_scope(nil), do: {:error, :missing_scope}
  defp normalize_scope(value), do: {:error, {:invalid_scope, value}}

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_optional_string(value), do: normalize_optional_string(to_string(value))

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_value), do: %{}

  defp limits(summary, keys) do
    keys
    |> Enum.map(fn key -> {key, field(summary, key)} end)
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_map, _key, default), do: default

  defp blank?(value), do: value in [nil, ""]

  defp drop_empty_values(map) do
    Map.reject(map, fn
      {_key, nil} -> true
      {_key, value} when value == %{} -> true
      {_key, value} when value == [] -> true
      _entry -> false
    end)
  end
end
