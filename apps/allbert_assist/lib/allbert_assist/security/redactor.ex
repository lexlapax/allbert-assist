defmodule AllbertAssist.Security.Redactor do
  @moduledoc """
  Central redaction policy for Security Central-facing values and metadata.
  """

  @redacted "[REDACTED]"
  @secret_ref "[SECRET_REF]"
  # v0.22 M2 audit closeout (moderate gap 10): expanded to cover
  # `raw_bridge_body`/`raw_final_state`/`raw_response` style fields that
  # downstream consumers (StockSage bridge, future advisory providers)
  # may dump into action maps. `authorization` and `bearer` catch
  # header-style credentials. Key-name redaction is the mechanism;
  # callers that need to dump raw secret content for debugging must
  # explicitly opt out at their own boundary, never silently.
  @sensitive_key_fragments [
    "api_key",
    "apikey",
    "secret",
    "token",
    "password",
    "credential",
    "raw_bridge",
    "raw_final",
    "raw_response",
    "authorization",
    "bearer"
  ]
  @status_keys ["credential_status", "secret_status", "secret_ref_display"]

  @type posture :: %{
          sensitive_key_fragments: nonempty_list(String.t()),
          secret_ref_display: String.t(),
          redacted_value: String.t(),
          surfaces: nonempty_list(atom())
        }

  @doc "Recursively redact sensitive keys, secret refs, structs, maps, and lists."
  @spec redact(term()) :: term()
  def redact(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.put(:__struct__, module_name(struct.__struct__))
    |> redact()
  end

  def redact(%{} = map) do
    Map.new(map, fn {key, value} ->
      if sensitive_key?(key) do
        {key, @redacted}
      else
        {key, redact(value)}
      end
    end)
  end

  def redact(list) when is_list(list), do: Enum.map(list, &redact/1)

  def redact("secret://" <> _rest), do: @secret_ref

  def redact(value), do: value

  @doc "Return a short posture summary suitable for operator status."
  @spec posture() :: posture()
  def posture do
    %{
      sensitive_key_fragments: @sensitive_key_fragments,
      secret_ref_display: @secret_ref,
      redacted_value: @redacted,
      surfaces: [:signals, :traces, :audits, :cli, :live_view, :logs, :tests]
    }
  end

  @doc "Return true if a key name should cause value redaction."
  @spec sensitive_key?(term()) :: boolean()
  def sensitive_key?(key) do
    normalized =
      key
      |> to_string()
      |> String.downcase()

    normalized not in @status_keys and
      Enum.any?(@sensitive_key_fragments, &String.contains?(normalized, &1))
  end

  defp module_name(module) when is_atom(module), do: inspect(module)
end
