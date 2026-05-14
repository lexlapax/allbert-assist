defmodule AllbertAssist.Channels.Identity do
  @moduledoc false

  @spec resolve(String.t(), String.t(), list()) ::
          {:ok, String.t()} | {:error, :not_mapped | :disabled}
  def resolve(_channel, external_user_id, identity_map)
      when is_binary(external_user_id) and is_list(identity_map) do
    normalized_external_user_id = normalize_external_user_id(external_user_id)

    identity_map
    |> Enum.find(fn entry ->
      normalize_external_user_id(field(entry, "external_user_id")) == normalized_external_user_id
    end)
    |> case do
      nil ->
        {:error, :not_mapped}

      entry ->
        if enabled?(entry) do
          {:ok, String.trim(to_string(field(entry, "user_id")))}
        else
          {:error, :disabled}
        end
    end
  end

  def resolve(_channel, _external_user_id, _identity_map), do: {:error, :not_mapped}

  defp enabled?(entry), do: field(entry, "enabled", true) != false

  defp normalize_external_user_id(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_external_user_id(value), do: value |> to_string() |> normalize_external_user_id()

  defp field(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, String.to_atom(key), default))
  end
end
