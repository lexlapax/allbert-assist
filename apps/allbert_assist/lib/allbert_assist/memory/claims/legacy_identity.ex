defmodule AllbertAssist.Memory.Claims.LegacyIdentity do
  @moduledoc """
  Deterministic, content-independent identity for an unadopted legacy Memory file.

  This is a pure helper. Claim authority remains in the file and the claim
  writer; deriving an id neither reads content nor grants authority.
  """

  import Bitwise

  @namespace "3a933b90-6d58-5d8c-9cdb-1233c996532f"
  @name_prefix "legacy-memory-v1\0"

  @doc "Derive the frozen UUIDv5 id from category and normalized Memory-relative path."
  @spec derive(String.t() | atom(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def derive(category, path, memory_root) when is_binary(path) and is_binary(memory_root) do
    with {:ok, category} <- category(category),
         {:ok, relative} <- relative_path(path, memory_root),
         {:ok, namespace} <- Ecto.UUID.dump(@namespace) do
      name = @name_prefix <> category <> <<0>> <> relative
      {:ok, uuid_v5(namespace, name)}
    end
  end

  def derive(_category, _path, _memory_root), do: {:error, :invalid_legacy_path}

  @doc "Normalize one path lexically beneath the resolved Memory root."
  @spec relative_path(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def relative_path(path, memory_root) do
    root = Path.expand(memory_root)
    expanded = Path.expand(path)

    if expanded != root and String.starts_with?(expanded, root <> "/") do
      relative =
        expanded
        |> Path.relative_to(root)
        |> String.replace("\\", "/")
        |> :unicode.characters_to_nfc_binary()

      {:ok, relative}
    else
      {:error, :path_outside_memory_root}
    end
  end

  defp uuid_v5(namespace, name) do
    <<time_low::32, time_mid::16, time_hi::16, clock_hi::8, clock_low::8, node::48>> =
      :crypto.hash(:sha, namespace <> name) |> binary_part(0, 16)

    time_hi = bor(band(time_hi, 0x0FFF), 0x5000)
    clock_hi = bor(band(clock_hi, 0x3F), 0x80)

    {:ok, uuid} =
      Ecto.UUID.load(
        <<time_low::32, time_mid::16, time_hi::16, clock_hi::8, clock_low::8, node::48>>
      )

    uuid
  end

  defp category(value) when is_atom(value), do: category(Atom.to_string(value))

  defp category(value) when is_binary(value) do
    value = value |> String.trim() |> :unicode.characters_to_nfc_binary()

    if Regex.match?(~r/^[a-z][a-z0-9_-]*$/, value),
      do: {:ok, value},
      else: {:error, :invalid_legacy_category}
  end

  defp category(_value), do: {:error, :invalid_legacy_category}
end
