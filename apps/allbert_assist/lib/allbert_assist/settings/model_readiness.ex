defmodule AllbertAssist.Settings.ModelReadiness do
  @moduledoc """
  Read-only callability assessment for Settings-owned model routes.

  One check resolves every requested role/profile from one Settings snapshot,
  then shares identical resolved local-profile probes across those resolutions.
  It never pulls a model, prompts the operator, writes Settings, or probes a
  hosted provider.
  """

  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.ModelDoctor
  alias AllbertAssist.Settings.ModelRuntime
  alias AllbertAssist.Settings.Models
  alias AllbertAssist.Settings.ProviderEligibility
  alias AllbertAssist.Settings.Store

  @type spec :: {:role, atom() | String.t()} | {:profile, String.t()}
  @type status :: :callable | :model_not_pulled | :unavailable
  @type reason ::
          nil
          | :profile_unavailable
          | :provider_disabled
          | :endpoint_unavailable
          | :availability_unknown
          | :credential_unavailable

  @type result :: %{
          callable?: boolean(),
          status: status(),
          reason: reason(),
          resolution_status: :resolved | :unavailable,
          profile: map() | nil,
          doctor: map() | nil
        }

  @doc "Assess a caller-keyed set of model roles or exact profile names."
  @spec check(%{optional(term()) => spec()}, map()) :: %{optional(term()) => result()}
  def check(specs, context \\ %{})

  def check(specs, context) when is_map(specs) and is_map(context) do
    Settings.with_resolved_settings(fn ->
      resolved = Map.new(specs, fn {id, spec} -> {id, resolve(spec, context)} end)
      probes = local_probes(resolved, context)

      Map.new(resolved, fn {id, resolution} ->
        {id, readiness(resolution, probes)}
      end)
    end)
  end

  def check(_specs, _context), do: %{}

  defp resolve({:role, role}, context) do
    case Models.for(role, context) do
      {:ok, %{profile: profile}} -> {:ok, profile}
      {:error, _reason} -> {:error, :profile_unavailable}
    end
  end

  defp resolve({:profile, profile_name}, _context) when is_binary(profile_name) do
    with {:ok, settings, user_settings} <- Store.resolved_settings(),
         {:ok, profile} <- Settings.resolve_model_profile(profile_name),
         {:ok, provider} <- provider_settings(profile, settings) do
      if ProviderEligibility.enabled?(profile.provider, provider, user_settings),
        do: {:ok, profile},
        else: {:disabled, profile}
    else
      _missing_or_invalid -> {:error, :profile_unavailable}
    end
  end

  defp resolve(_spec, _context), do: {:error, :profile_unavailable}

  defp local_probes(resolved, context) do
    resolved
    |> Enum.reduce(%{}, fn
      {_id, {:ok, profile}}, acc ->
        case ModelRuntime.effective_transport(profile) do
          {:ok, %{endpoint_class: :local}} ->
            Map.put_new(acc, local_probe_key(profile), profile)

          _hosted_or_invalid ->
            acc
        end

      _other, acc ->
        acc
    end)
    |> Map.new(fn {key, profile} -> {key, diagnose_local(profile, context)} end)
  end

  defp diagnose_local(profile, context) do
    case ModelDoctor.diagnose(profile.name, context) do
      {:ok, doctor} ->
        doctor
        |> Map.put(:profile, profile.name)
        |> Map.put(:model, profile.model)
        |> Map.put(:provider, profile.provider)

      {:error, _reason} ->
        nil
    end
  end

  defp readiness({:error, _reason}, _probes), do: unavailable(nil, :profile_unavailable, nil)

  defp readiness({:disabled, profile}, _probes),
    do: unavailable(profile, :provider_disabled, nil)

  defp readiness({:ok, profile}, probes) do
    case ModelRuntime.effective_transport(profile) do
      {:ok, %{endpoint_class: :local}} -> readiness_local(profile, probes)
      {:ok, %{endpoint_class: :hosted}} -> readiness_hosted(profile)
      {:error, _reason} -> unavailable(profile, :endpoint_unavailable, nil)
    end
  end

  defp readiness_local(profile, probes) do
    doctor = Map.get(probes, local_probe_key(profile))

    if is_map(doctor),
      do: readiness_from_local_doctor(profile, doctor),
      else: unavailable(profile, :availability_unknown, doctor)
  end

  defp readiness_from_local_doctor(profile, doctor) do
    case doctor.endpoint_ok do
      true -> readiness_from_local_model(profile, doctor, doctor.model_available)
      false -> unavailable(profile, :endpoint_unavailable, doctor)
      _unknown -> unavailable(profile, :availability_unknown, doctor)
    end
  end

  defp readiness_from_local_model(profile, doctor, true), do: available(profile, doctor)

  defp readiness_from_local_model(profile, doctor, false),
    do: unavailable(profile, :model_not_pulled, doctor, :model_not_pulled)

  defp readiness_from_local_model(profile, doctor, _unknown),
    do: unavailable(profile, :availability_unknown, doctor)

  defp readiness_hosted(%{credential_status: :configured} = profile) do
    available(profile, nil)
  end

  defp readiness_hosted(%{provider_endpoint_kind: kind} = profile)
       when kind in [:credentialed_remote, "credentialed_remote"] do
    unavailable(profile, :credential_unavailable, nil)
  end

  defp readiness_hosted(profile),
    do: unavailable(profile, :availability_unknown, nil)

  defp available(profile, doctor) do
    %{
      callable?: true,
      status: :callable,
      reason: nil,
      resolution_status: :resolved,
      profile: profile,
      doctor: doctor
    }
  end

  defp unavailable(profile, reason, doctor, status \\ :unavailable) do
    %{
      callable?: false,
      status: status,
      reason: reason,
      resolution_status: if(is_map(profile), do: :resolved, else: :unavailable),
      profile: profile,
      doctor: doctor
    }
  end

  defp local_probe_key(profile) do
    endpoint_key =
      case ModelRuntime.effective_transport(profile) do
        {:ok, %{endpoint_sha256: endpoint_sha256}} -> endpoint_sha256
        {:error, reason} -> {:invalid_effective_endpoint, reason}
      end

    {
      profile.provider,
      profile.provider_type,
      endpoint_key,
      profile.model,
      profile.aliases |> List.wrap() |> Enum.sort(),
      profile.timeout_ms
    }
  end

  defp provider_settings(%{provider: provider_name}, settings) when is_binary(provider_name) do
    case get_in(settings, ["providers", provider_name]) do
      provider when is_map(provider) -> {:ok, provider}
      _missing -> {:error, :provider_unavailable}
    end
  end

  defp provider_settings(_profile, _settings), do: {:error, :provider_unavailable}
end
