defmodule AllbertAssist.Security.Status do
  @moduledoc """
  Read-only Security Central status summaries for operator surfaces.
  """

  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Security.Policy
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Schema
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Settings.Store

  @future_boundaries [
    %{name: :confirmation_queue, milestone: "v0.07", status: :implemented},
    %{name: :shell_sandbox, milestone: "v0.08", status: :implemented},
    %{name: :skill_script_runner, milestone: "v0.09", status: :implemented},
    %{name: :external_adapters_and_imports, milestone: "v0.10", status: :implemented}
  ]

  @doc "Return redacted read-only security status."
  @spec summary(map()) :: map()
  def summary(context \\ %{}) when is_map(context) do
    status =
      case Store.resolved_settings() do
        {:ok, settings, _user_settings} ->
          summary_from_settings(context, settings)

        {:error, reason} ->
          summary_from_settings_error(context, reason)
      end

    Redactor.redact(status)
  end

  defp summary_from_settings(context, settings) do
    %{
      permission_defaults: permission_defaults(context, settings),
      safety_floors: safety_floors(),
      skill_trust: skill_trust_summary(settings),
      capability_boundaries: capability_boundaries_summary(settings),
      secret_status: secret_status_summary(settings),
      redaction_posture: Redactor.posture(),
      future_boundaries: @future_boundaries
    }
  end

  defp summary_from_settings_error(context, reason) do
    settings_error = inspect(reason)

    %{
      permission_defaults: permission_defaults(context, %{}),
      safety_floors: safety_floors(),
      skill_trust: %{error: settings_error},
      capability_boundaries: capability_boundaries_summary(Settings.defaults()),
      secret_status: %{error: settings_error},
      redaction_posture: Redactor.posture(),
      future_boundaries: @future_boundaries
    }
  end

  defp permission_defaults(context, settings) do
    Enum.map(Policy.permission_policies(context, settings), fn policy ->
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

  defp skill_trust_summary(settings) do
    skill_settings = settings_entries(settings, "skills")

    %{
      configured_settings: length(skill_settings),
      enabled_count: count_setting(skill_settings, "skills.enabled"),
      disabled_count: count_setting(skill_settings, "skills.disabled"),
      trusted_project_roots_count: count_setting(skill_settings, "skills.trusted_project_roots")
    }
  end

  defp secret_status_summary(settings) do
    credential_statuses =
      settings
      |> Map.get("providers", %{})
      |> Enum.map(fn {_name, attrs} -> attrs |> Map.get("api_key_ref") |> secret_status() end)

    %{
      providers: length(credential_statuses),
      configured: Enum.count(credential_statuses, &(&1 == :configured)),
      missing: Enum.count(credential_statuses, &(&1 == :missing))
    }
  end

  defp capability_boundaries_summary(settings) do
    %{
      external_services: %{
        enabled: setting(settings, "external_services.enabled", false),
        allowed_hosts_count: length(setting(settings, "external_services.allowed_hosts", [])),
        allowed_methods: setting(settings, "external_services.allowed_methods", []),
        profiles_count: map_size(setting(settings, "external_services.profiles", %{})),
        allow_redirects: setting(settings, "external_services.allow_redirects", false),
        retry_policy: setting(settings, "external_services.retry_policy", "none"),
        max_response_bytes: setting(settings, "external_services.max_response_bytes", nil)
      },
      package_installs: %{
        enabled: setting(settings, "package_installs.enabled", false),
        allowed_roots_count: length(setting(settings, "package_installs.allowed_roots", [])),
        allowed_managers: setting(settings, "package_installs.allowed_managers", []),
        lifecycle_scripts_allowed:
          setting(settings, "package_installs.lifecycle_scripts_allowed", false),
        git_dependencies_allowed:
          setting(settings, "package_installs.git_dependencies_allowed", false),
        global_installs_allowed:
          setting(settings, "package_installs.global_installs_allowed", false),
        max_output_bytes: setting(settings, "package_installs.max_output_bytes", nil)
      },
      online_skill_import: %{
        enabled: setting(settings, "skills.online_import.enabled", false),
        allowed_sources: setting(settings, "skills.online_import.allowed_sources", []),
        max_listing_results: setting(settings, "skills.online_import.max_listing_results", nil),
        max_download_bytes: setting(settings, "skills.online_import.max_download_bytes", nil),
        trust_after_import: setting(settings, "skills.online_import.trust_after_import", false)
      },
      plugin_app_registration: %{
        plugins_registration_enabled: setting(settings, "plugins.registration_enabled", true),
        app_registry_registration_enabled:
          setting(settings, "app_registry.registration_enabled", true)
      },
      workspace_fragments: %{
        emission_enabled: setting(settings, "workspace.fragment.emission_enabled", true),
        rate_limit_per_second: setting(settings, "workspace.fragment.rate_limit_per_second", nil),
        receiver_rate_limit_per_second:
          setting(settings, "workspace.fragment.receiver_rate_limit_per_second", nil),
        payload_max_bytes: setting(settings, "workspace.fragment.payload_max_bytes", nil)
      }
    }
  end

  defp count_setting(settings_entries, key) do
    settings_entries
    |> Enum.find({key, []}, fn {setting_key, _value} -> setting_key == key end)
    |> elem(1)
    |> case do
      values when is_list(values) -> length(values)
      _other -> 0
    end
  end

  defp setting(settings, key, default) do
    case Schema.get_dotted(settings, key) do
      nil -> default
      value -> value
    end
  end

  defp secret_status(nil), do: :missing
  defp secret_status(secret_ref), do: Secrets.status(secret_ref)

  defp settings_entries(settings, namespace) do
    settings
    |> flatten_settings()
    |> Enum.filter(fn {key, _value} -> String.starts_with?(key, namespace) end)
  end

  defp flatten_settings(settings), do: flatten_settings(settings, [])

  defp flatten_settings(settings, prefix) when is_map(settings) do
    Enum.flat_map(settings, fn {key, value} -> flatten_settings(value, prefix ++ [key]) end)
  end

  defp flatten_settings(value, prefix), do: [{Enum.join(prefix, "."), value}]
end
