defmodule AllbertAssist.Memory.SecretFilter do
  @moduledoc """
  Deterministic credential-shaped input refusal for Memory proposals.

  The filter reports only a boolean to callers. It does not return, log, or
  persist matching content.
  """

  @patterns [
    ~r/\bsk-[A-Za-z0-9_-]{20,}\b/,
    ~r/\bAIza[0-9A-Za-z_-]{20,}\b/,
    ~r/\bgh[pousr]_[A-Za-z0-9_]{20,}\b/,
    ~r/\bxox[baprs]-[A-Za-z0-9-]{20,}\b/,
    ~r/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/,
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/,
    ~r/(?:token|api[_-]?key|password|secret|bearer)\s*[:=]\s*(?!\[REDACTED\]|secret:\/\/)[^\s"',}]{8,}/i
  ]

  @doc "Return true when any nested binary contains a credential-shaped value."
  def secret_bearing?(value), do: walk(value)

  defp walk(%_{} = struct), do: struct |> Map.from_struct() |> walk()

  defp walk(map) when is_map(map),
    do: Enum.any?(map, fn {key, value} -> walk(key) or walk(value) end)

  defp walk(list) when is_list(list), do: Enum.any?(list, &walk/1)
  defp walk(value) when is_atom(value), do: value |> Atom.to_string() |> walk()
  defp walk(value) when is_binary(value), do: Enum.any?(@patterns, &Regex.match?(&1, value))
  defp walk(_value), do: false
end
