defmodule AllbertAssist.Database.TransientError do
  @moduledoc """
  Closed classification for transient database failures that are safe to retry.

  This is a plain module because it owns no process state. It recognizes only
  the DBConnection ownership/connection exceptions and Exqlite busy/locked
  errors already treated as transient by the objective runtime; arbitrary
  strings and unknown exceptions remain programming or permanent failures.
  """

  alias AllbertAssist.Runtime.Redactor

  @max_summary_bytes 240
  @sqlite_transient_messages [
    "database is busy",
    "database is locked",
    "database table is locked"
  ]

  @doc "Return whether a nested reason contains a known transient database failure."
  @spec transient?(term()) :: boolean()
  def transient?(%DBConnection.ConnectionError{}), do: true
  def transient?(%DBConnection.OwnershipError{}), do: true

  def transient?(%Exqlite.Error{message: message}) do
    message = String.downcase(message || "")
    Enum.any?(@sqlite_transient_messages, &String.contains?(message, &1))
  end

  def transient?(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.any?(&transient?/1)
  end

  def transient?(reason) when is_list(reason), do: Enum.any?(reason, &transient?/1)
  def transient?(_reason), do: false

  @doc "Return a bounded redacted description suitable for an error result or log."
  @spec summary(term()) :: String.t()
  def summary(reason) do
    reason
    |> Redactor.redact(:signals)
    |> inspect(limit: 10, printable_limit: @max_summary_bytes)
    |> String.slice(0, @max_summary_bytes)
  end
end
