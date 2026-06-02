defmodule AllbertAssist.Marketplace.Provenance do
  @moduledoc """
  Marketplace provenance validation for the v0.45 shipped-only catalog.
  """

  alias AllbertAssist.Marketplace.Diagnostic

  @allowed_keys ~w[scheme source_git_commit review_date]
  @required_keys @allowed_keys

  @spec validate(term(), [String.t() | non_neg_integer()]) :: :ok | {:error, map()}
  def validate(provenance, pointer) when is_map(provenance) do
    with :ok <- reject_unknown_keys(provenance, pointer),
         :ok <- require_keys(provenance, pointer),
         :ok <- validate_scheme(Map.get(provenance, "scheme"), pointer ++ ["scheme"]),
         :ok <-
           validate_commit(
             Map.get(provenance, "source_git_commit"),
             pointer ++ ["source_git_commit"]
           ) do
      validate_review_date(Map.get(provenance, "review_date"), pointer ++ ["review_date"])
    end
  end

  def validate(_provenance, pointer) do
    {:error,
     Diagnostic.new(
       :catalog_invalid,
       :expected_object,
       "provenance must be an object",
       pointer: Diagnostic.pointer(pointer)
     )}
  end

  defp reject_unknown_keys(map, pointer) do
    case Enum.find(Map.keys(map), &(&1 not in @allowed_keys)) do
      nil ->
        :ok

      key ->
        {:error,
         Diagnostic.new(:catalog_invalid, :unknown_key, "unknown provenance key #{key}",
           pointer: Diagnostic.pointer(pointer ++ [key])
         )}
    end
  end

  defp require_keys(map, pointer) do
    case Enum.find(@required_keys, &(not Map.has_key?(map, &1))) do
      nil ->
        :ok

      key ->
        {:error,
         Diagnostic.new(
           :catalog_invalid,
           :missing_required_field,
           "missing provenance key #{key}",
           pointer: Diagnostic.pointer(pointer ++ [key])
         )}
    end
  end

  defp validate_scheme("shipped", _pointer), do: :ok

  defp validate_scheme(scheme, pointer) do
    {:error,
     Diagnostic.new(
       :catalog_unknown_provenance_scheme,
       :unknown_provenance_scheme,
       "unsupported marketplace provenance scheme #{inspect(scheme)}",
       pointer: Diagnostic.pointer(pointer)
     )}
  end

  defp validate_commit(value, _pointer) when is_binary(value) and byte_size(value) >= 7, do: :ok

  defp validate_commit(value, pointer) do
    {:error,
     Diagnostic.new(:catalog_invalid, :invalid_source_git_commit, "invalid source git commit",
       pointer: Diagnostic.pointer(pointer),
       details: %{value: value}
     )}
  end

  defp validate_review_date(value, pointer) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, _date} -> :ok
      {:error, _reason} -> invalid_review_date(value, pointer)
    end
  end

  defp validate_review_date(value, pointer), do: invalid_review_date(value, pointer)

  defp invalid_review_date(value, pointer) do
    {:error,
     Diagnostic.new(:catalog_invalid, :invalid_review_date, "invalid review date",
       pointer: Diagnostic.pointer(pointer),
       details: %{value: value}
     )}
  end
end
