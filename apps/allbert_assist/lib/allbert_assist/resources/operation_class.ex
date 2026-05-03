defmodule AllbertAssist.Resources.OperationClass do
  @moduledoc """
  Closed vocabulary for resource access posture fields.

  The values here are descriptive data for confirmations, traces, audits, and
  future approval handoff. They do not grant permission or execute work.
  """

  @origin_kinds ~w[
    local_path
    local_skill_resource
    allbert_home
    remote_url
    remote_source
    package_registry
  ]a

  @operation_classes ~w[
    read_local_path
    write_local_path
    run_shell_command
    run_skill_script
    import_local_skill
    external_service_request
    online_skill_search
    online_skill_detail
    online_skill_audit
    online_skill_import
    summarize_url
    inspect_document
    import_skill
    package_install
  ]a

  @access_modes ~w[
    read
    write
    execute
    fetch
    import
    summarize
    install
    audit
  ]a

  @scope_kinds ~w[
    exact_file
    directory_subtree
    exact_url
    url_prefix
    source_profile
    package_target_root
    skill_resource_id
  ]a

  @default_access_modes %{
    read_local_path: :read,
    write_local_path: :write,
    run_shell_command: :execute,
    run_skill_script: :execute,
    import_local_skill: :import,
    external_service_request: :fetch,
    online_skill_search: :fetch,
    online_skill_detail: :fetch,
    online_skill_audit: :audit,
    online_skill_import: :import,
    summarize_url: :summarize,
    inspect_document: :read,
    import_skill: :import,
    package_install: :install
  }

  @type origin_kind ::
          :local_path
          | :local_skill_resource
          | :allbert_home
          | :remote_url
          | :remote_source
          | :package_registry

  @type operation_class ::
          :read_local_path
          | :write_local_path
          | :run_shell_command
          | :run_skill_script
          | :import_local_skill
          | :external_service_request
          | :online_skill_search
          | :online_skill_detail
          | :online_skill_audit
          | :online_skill_import
          | :summarize_url
          | :inspect_document
          | :import_skill
          | :package_install

  @type access_mode ::
          :read
          | :write
          | :execute
          | :fetch
          | :import
          | :summarize
          | :install
          | :audit

  @type scope_kind ::
          :exact_file
          | :directory_subtree
          | :exact_url
          | :url_prefix
          | :source_profile
          | :package_target_root
          | :skill_resource_id

  @spec origin_kinds() :: nonempty_list(origin_kind())
  def origin_kinds, do: @origin_kinds

  @spec operation_classes() :: nonempty_list(operation_class())
  def operation_classes, do: @operation_classes

  @spec access_modes() :: nonempty_list(access_mode())
  def access_modes, do: @access_modes

  @spec scope_kinds() :: nonempty_list(scope_kind())
  def scope_kinds, do: @scope_kinds

  @spec default_access_mode(operation_class() | String.t()) :: access_mode()
  def default_access_mode(operation_class) do
    operation_class
    |> operation_class!()
    |> then(&Map.fetch!(@default_access_modes, &1))
  end

  @spec origin_kind(term()) :: {:ok, origin_kind()} | {:error, {:unknown_origin_kind, term()}}
  def origin_kind(value), do: normalize(value, @origin_kinds, :unknown_origin_kind)

  @spec origin_kind!(term()) :: origin_kind()
  def origin_kind!(value), do: normalize!(value, @origin_kinds, :unknown_origin_kind)

  @spec operation_class(term()) ::
          {:ok, operation_class()} | {:error, {:unknown_operation_class, term()}}
  def operation_class(value), do: normalize(value, @operation_classes, :unknown_operation_class)

  @spec operation_class!(term()) :: operation_class()
  def operation_class!(value), do: normalize!(value, @operation_classes, :unknown_operation_class)

  @spec access_mode(term()) :: {:ok, access_mode()} | {:error, {:unknown_access_mode, term()}}
  def access_mode(value), do: normalize(value, @access_modes, :unknown_access_mode)

  @spec access_mode!(term()) :: access_mode()
  def access_mode!(value), do: normalize!(value, @access_modes, :unknown_access_mode)

  @spec scope_kind(term()) :: {:ok, scope_kind()} | {:error, {:unknown_scope_kind, term()}}
  def scope_kind(value), do: normalize(value, @scope_kinds, :unknown_scope_kind)

  @spec scope_kind!(term()) :: scope_kind()
  def scope_kind!(value), do: normalize!(value, @scope_kinds, :unknown_scope_kind)

  defp normalize(value, allowed, error_tag) do
    normalized = normalize_atom(value)

    if normalized in allowed do
      {:ok, normalized}
    else
      {:error, {error_tag, value}}
    end
  end

  defp normalize!(value, allowed, error_tag) do
    case normalize(value, allowed, error_tag) do
      {:ok, normalized} -> normalized
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  defp normalize_atom(value) when is_atom(value), do: value

  defp normalize_atom(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> String.to_existing_atom()
  rescue
    ArgumentError -> nil
  end

  defp normalize_atom(_value), do: nil
end
