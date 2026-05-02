defmodule AllbertAssist.Security.Status do
  @moduledoc """
  Read-only Security Central status summaries for operator surfaces.
  """

  alias AllbertAssist.Security.Policy
  alias AllbertAssist.Security.Redactor
  alias AllbertAssist.Settings

  @future_boundaries [
    %{name: :confirmation_queue, milestone: "v0.07", status: :implemented},
    %{name: :shell_sandbox, milestone: "v0.08", status: :implemented},
    %{name: :skill_script_runner, milestone: "v0.09", status: :planned},
    %{name: :external_adapters_and_imports, milestone: "v0.10", status: :planned}
  ]

  @doc "Return redacted read-only security status."
  @spec summary(map()) :: map()
  def summary(context \\ %{}) when is_map(context) do
    %{
      permission_defaults: permission_defaults(context),
      safety_floors: safety_floors(),
      skill_trust: skill_trust_summary(),
      secret_status: secret_status_summary(),
      redaction_posture: Redactor.posture(),
      future_boundaries: @future_boundaries
    }
    |> Redactor.redact()
  end

  defp permission_defaults(context) do
    Enum.map(Policy.permission_policies(context), fn policy ->
      %{
        permission: policy.permission,
        setting_key: policy.setting_key,
        configured: policy.configured,
        configured_decision: policy.configured_decision,
        effective: policy.effective,
        source: policy.source,
        capped?: policy.capped?,
        reason: policy.reason
      }
    end)
  end

  defp safety_floors do
    Enum.map(Policy.permission_classes() ++ [:unknown], fn permission ->
      %{permission: permission, floor: Policy.safety_floor(permission)}
    end)
  end

  defp skill_trust_summary do
    case Settings.list("skills") do
      {:ok, settings} ->
        %{
          configured_settings: length(settings),
          enabled_count: count_setting(settings, "skills.enabled"),
          disabled_count: count_setting(settings, "skills.disabled"),
          trusted_project_roots_count: count_setting(settings, "skills.trusted_project_roots")
        }

      {:error, reason} ->
        %{error: inspect(reason)}
    end
  end

  defp secret_status_summary do
    case Settings.list_provider_profiles() do
      {:ok, providers} ->
        %{
          providers: length(providers),
          configured: Enum.count(providers, &(&1.credential_status == :configured)),
          missing: Enum.count(providers, &(&1.credential_status == :missing))
        }

      {:error, reason} ->
        %{error: inspect(reason)}
    end
  end

  defp count_setting(settings, key) do
    settings
    |> Enum.find(%{value: []}, &(&1.key == key))
    |> Map.get(:value)
    |> case do
      values when is_list(values) -> length(values)
      _other -> 0
    end
  end
end
