defmodule AllbertAssist.Settings.DoctorDiagnostics do
  @moduledoc """
  Fixed ADR 0047 diagnostic catalog for provider-style doctors.

  Diagnostics are safe to surface in CLI, LiveView, traces, and audits. Codes
  carry the machine-readable detail; messages are fixed catalog copy and do not
  echo provider responses, raw URLs, paths, token fragments, or exception terms.
  """

  @max_message_bytes 256

  @catalog %{
    credential_missing: "Provider credential is not configured.",
    credential_rejected: "Provider rejected the configured credential.",
    credential_unavailable: "Provider credential could not be read.",
    doctor_failed: "Doctor could not complete for the configured profile.",
    endpoint_http_error: "Provider endpoint returned an HTTP error.",
    endpoint_unreachable: "Provider endpoint did not respond.",
    invalid_catalog_response: "Provider returned an unreadable model list.",
    invalid_provider_base_url: "Provider base URL is invalid.",
    local_model_missing:
      "Configured local model is not installed. Pull the configured model and retry.",
    model_not_listed: "Configured model was not listed by provider.",
    provider_host_denied: "Provider host is not allowed by doctor policy.",
    rate_limited: "Provider rate-limited the model-list probe.",
    voice_capability_missing: "Configured profile does not advertise a voice capability.",
    voice_provider_probe_unavailable:
      "Voice provider probe is not available for this deployment mode yet."
  }

  @spec catalog() :: %{atom() => String.t()}
  def catalog, do: @catalog

  @spec codes() :: [atom()]
  def codes, do: @catalog |> Map.keys() |> Enum.sort()

  @spec known?(atom()) :: boolean()
  def known?(code) when is_atom(code), do: Map.has_key?(@catalog, code)
  def known?(_code), do: false

  @spec new(atom()) :: %{code: atom(), message: String.t()}
  def new(code) when is_atom(code) do
    code = if known?(code), do: code, else: :doctor_failed
    %{code: code, message: @catalog |> Map.fetch!(code) |> cap_message()}
  end

  def new(_code), do: new(:doctor_failed)

  defp cap_message(message) when byte_size(message) <= @max_message_bytes, do: message
  defp cap_message(message), do: binary_part(message, 0, @max_message_bytes)
end
