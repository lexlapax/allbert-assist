defmodule AllbertAssist.Pack.Descriptor do
  @moduledoc """
  Stable identity carried by a descriptor-bearing Pack application.
  """

  alias AllbertAssist.Pack.Identity

  @enforce_keys [
    :schema_version,
    :id,
    :application,
    :application_version,
    :capability_tier,
    :provenance,
    :registry_order
  ]
  defstruct @enforce_keys
  @descriptor_keys Enum.sort([:__struct__ | @enforce_keys])

  @type capability_tier :: :kernel | :native
  @type provenance :: %{source: :signed_release, component: String.t()}

  @type t :: %__MODULE__{
          schema_version: 1,
          id: String.t(),
          application: atom(),
          application_version: String.t(),
          capability_tier: capability_tier(),
          provenance: provenance(),
          registry_order: non_neg_integer()
        }

  @spec validate(term()) :: {:ok, t()} | {:error, {:invalid_descriptor, atom()}}
  def validate(%__MODULE__{} = descriptor) do
    with :ok <- validate_shape(descriptor),
         :ok <- validate_schema_version(descriptor),
         :ok <- validate_id(descriptor),
         :ok <- validate_application(descriptor),
         :ok <- validate_application_version(descriptor),
         :ok <- validate_capability_tier(descriptor),
         :ok <- validate_provenance(descriptor),
         :ok <- validate_registry_order(descriptor) do
      {:ok, descriptor}
    end
  end

  def validate(_other), do: invalid(:shape)

  defp validate_shape(descriptor) do
    if Enum.sort(Map.keys(descriptor)) == @descriptor_keys,
      do: :ok,
      else: invalid(:shape)
  end

  defp validate_schema_version(%{schema_version: 1}), do: :ok
  defp validate_schema_version(_descriptor), do: invalid(:schema_version)

  defp validate_id(%{id: id}) do
    if valid_id?(id), do: :ok, else: invalid(:id)
  end

  defp validate_application(%{application: application}) do
    if valid_application?(application), do: :ok, else: invalid(:application)
  end

  defp validate_application_version(%{application_version: version}) do
    if nonempty_string?(version), do: :ok, else: invalid(:application_version)
  end

  defp validate_capability_tier(%{capability_tier: tier}) when tier in [:kernel, :native],
    do: :ok

  defp validate_capability_tier(_descriptor), do: invalid(:capability_tier)

  defp validate_provenance(%{provenance: provenance}) do
    if valid_provenance?(provenance), do: :ok, else: invalid(:provenance)
  end

  defp validate_registry_order(%{registry_order: order}) do
    if valid_order?(order), do: :ok, else: invalid(:registry_order)
  end

  defp valid_id?(id), do: Identity.canonical_id?(id)

  defp valid_application?(application), do: Identity.canonical_application?(application)

  defp valid_provenance?(%{source: :signed_release, component: component} = provenance)
       when map_size(provenance) == 2,
       do: Identity.canonical_component?(component)

  defp valid_provenance?(_provenance), do: false

  defp valid_order?(order), do: is_integer(order) and order >= 0
  defp nonempty_string?(value), do: is_binary(value) and byte_size(value) > 0
  defp invalid(field), do: {:error, {:invalid_descriptor, field}}
end
