defmodule AllbertAssist.Settings.ProviderEligibility do
  @moduledoc """
  Read-only provider eligibility shared by model selection and resolution.

  A raw operator disable is authoritative. For a credentialed remote provider,
  a present vault or environment credential makes the schema-default disabled
  provider eligible without persisting an additional provider setting. This
  check never probes or sends traffic to the provider.
  """

  alias AllbertAssist.Settings.Vault

  @credentialed_remote "credentialed_remote"

  @doc "Whether the provider is enabled for model resolution."
  @spec enabled?(String.t(), map(), map()) :: boolean()
  def enabled?(provider_name, provider, user_settings)
      when is_binary(provider_name) and is_map(provider) and is_map(user_settings) do
    case get_in(user_settings, ["providers", provider_name, "enabled"]) do
      false -> false
      true -> true
      nil -> provider["enabled"] == true or default_hosted_credential_present?(provider)
      _invalid -> false
    end
  end

  def enabled?(_provider_name, _provider, _user_settings), do: false

  @doc "Whether a configured-but-unverified hosted provider may be selected."
  @spec hosted_eligible?(String.t(), map(), map()) :: boolean()
  def hosted_eligible?(provider_name, provider, user_settings)
      when is_binary(provider_name) and is_map(provider) and is_map(user_settings) do
    provider["endpoint_kind"] == @credentialed_remote and
      case get_in(user_settings, ["providers", provider_name, "enabled"]) do
        false -> false
        enabled when enabled in [true, nil] -> credential_present?(provider)
        _invalid -> false
      end
  end

  def hosted_eligible?(_provider_name, _provider, _user_settings), do: false

  defp default_hosted_credential_present?(%{"endpoint_kind" => @credentialed_remote} = provider),
    do: credential_present?(provider)

  defp default_hosted_credential_present?(_provider), do: false

  defp credential_present?(%{"credential_status" => :configured}), do: true

  defp credential_present?(%{"api_key_ref" => ref}) when is_binary(ref) do
    case Vault.get(ref, %{trusted?: true, purpose: :provider_eligibility}) do
      {:ok, value} when is_binary(value) -> value != ""
      _missing_or_error -> false
    end
  end

  defp credential_present?(_provider), do: false
end
