defmodule AllbertAssist.Resources.Scope do
  @moduledoc """
  Inert resource scope descriptor.

  A scope describes what a resource reference points at. It does not imply that
  the resource is allowed or trusted.
  """

  alias AllbertAssist.Resources.OperationClass

  @enforce_keys [:kind, :value]
  defstruct [:kind, :value]

  @type t :: %__MODULE__{kind: atom(), value: String.t()}

  @spec new(term(), term()) :: {:ok, t()} | {:error, term()}
  def new(kind, value) do
    with {:ok, kind} <- OperationClass.scope_kind(kind),
         {:ok, value} <- normalize_value(value) do
      {:ok, %__MODULE__{kind: kind, value: value}}
    end
  end

  @spec new!(term(), term()) :: t()
  def new!(kind, value) do
    case new(kind, value) do
      {:ok, scope} -> scope
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  @spec exact_file(term()) :: t()
  def exact_file(value), do: new!(:exact_file, value)

  @spec directory_subtree(term()) :: t()
  def directory_subtree(value), do: new!(:directory_subtree, value)

  @spec exact_url(term()) :: t()
  def exact_url(value), do: new!(:exact_url, value)

  @spec url_prefix(term()) :: t()
  def url_prefix(value), do: new!(:url_prefix, value)

  @spec source_profile(term()) :: t()
  def source_profile(value), do: new!(:source_profile, value)

  @spec package_target_root(term()) :: t()
  def package_target_root(value), do: new!(:package_target_root, value)

  @spec skill_resource_id(term()) :: t()
  def skill_resource_id(value), do: new!(:skill_resource_id, value)

  @spec mcp_server(term()) :: t()
  def mcp_server(value), do: new!(:mcp_server, value)

  @spec mcp_tool(term()) :: t()
  def mcp_tool(value), do: new!(:mcp_tool, value)

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = scope) do
    %{kind: scope.kind, value: scope.value}
  end

  defp normalize_value(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: {:error, :empty_scope_value}, else: {:ok, value}
  end

  defp normalize_value(value) when is_atom(value), do: normalize_value(Atom.to_string(value))

  defp normalize_value(value) when is_integer(value),
    do: normalize_value(Integer.to_string(value))

  defp normalize_value(nil), do: {:error, :missing_scope_value}
  defp normalize_value(value), do: normalize_value(to_string(value))
end
