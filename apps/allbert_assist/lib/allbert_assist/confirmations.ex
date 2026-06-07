defmodule AllbertAssist.Confirmations do
  @moduledoc """
  Durable confirmation request domain.

  Runtime-facing approval and denial enter through registered actions. This
  module is the plain Elixir facade those actions use behind the boundary.
  """

  alias AllbertAssist.Confirmations.Store
  alias AllbertAssist.Runtime.Redactor

  @adapter_unavailable_note "Approved, but not executed: this historical target had no adapter when it was created. New v0.10 external-network requests use the confirmed Req adapter."

  defdelegate root(), to: Store
  defdelegate ensure_root!(), to: Store
  defdelegate create(attrs, opts \\ []), to: Store
  defdelegate read(id), to: Store
  defdelegate list(opts \\ []), to: Store
  defdelegate resolve(id, status, resolution_attrs \\ %{}, opts \\ []), to: Store
  defdelegate annotate_resolution(id, attrs, opts \\ []), to: Store
  defdelegate expire(opts \\ []), to: Store

  @doc """
  Redact confirmation internals before returning records through operator-facing
  action responses.

  Approval uses the stored record directly. This helper is for list/show/approve
  output where resumable voice payloads must not expose local audio paths or the
  full text being synthesized.
  """
  @spec redact_for_output(map()) :: map()
  def redact_for_output(%{} = record) do
    case get_in(record, ["target_action", "name"]) do
      "transcribe_voice" ->
        redact_resume_params(record, %{
          "audio_file" => "[REDACTED_AUDIO_PATH]",
          "file" => "[REDACTED_AUDIO_PATH]",
          "path" => "[REDACTED_AUDIO_PATH]",
          "resource_uri" =>
            Redactor.redact_audio_resource_uri(
              get_in(record, ["resume_params_ref", "resource_uri"])
            )
        })

      "synthesize_voice" ->
        redact_resume_params(record, %{
          "text" => "[REDACTED]",
          "input" => "[REDACTED]",
          "prompt" => "[REDACTED]",
          "output_format" => get_in(record, ["resume_params_ref", "output_format"]),
          "voice" => get_in(record, ["resume_params_ref", "voice"])
        })

      _other ->
        record
    end
  end

  def redact_for_output(record), do: record

  @doc "Return the operator-facing explanation for adapter-unavailable approvals."
  @spec adapter_unavailable_note() :: String.t()
  def adapter_unavailable_note, do: @adapter_unavailable_note

  @doc "Return a human-readable status note for confirmation records that need one."
  @spec status_note(map()) :: String.t() | nil
  def status_note(%{"status" => "adapter_unavailable"}), do: @adapter_unavailable_note
  def status_note(_record), do: nil

  @doc "Return the standard operator-facing confirmation resolution message."
  @spec status_message(map()) :: String.t()
  def status_message(record) when is_map(record) do
    message = "Confirmation #{record["id"]} is #{record["status"]}."

    case status_note(record) do
      nil -> message
      note -> "#{message} #{note}"
    end
  end

  defp redact_resume_params(record, replacement) do
    Map.put(
      record,
      "resume_params_ref",
      replacement
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    )
  end
end
