defmodule AllbertAssist.Security.Status do
  @moduledoc """
  Read-only Security Central status summaries for operator surfaces.
  """

  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Security.Policy
  alias AllbertAssist.Settings

  @future_boundaries [
    %{name: :confirmation_queue, milestone: "v0.07", status: :implemented},
    %{name: :shell_sandbox, milestone: "v0.08", status: :implemented},
    %{name: :skill_script_runner, milestone: "v0.09", status: :implemented},
    %{name: :external_adapters_and_imports, milestone: "v0.10", status: :implemented}
  ]

  @doc "Return redacted read-only security status."
  @spec summary(map()) :: map()
  def summary(context \\ %{}) when is_map(context) do
    %{
      permission_defaults: permission_defaults(context),
      safety_floors: safety_floors(),
      skill_trust: skill_trust_summary(),
      capability_boundaries: capability_boundaries_summary(),
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

  defp capability_boundaries_summary do
    %{
      external_services: %{
        enabled: setting("external_services.enabled", false),
        allowed_hosts_count: length(setting("external_services.allowed_hosts", [])),
        allowed_methods: setting("external_services.allowed_methods", []),
        profiles_count: map_size(setting("external_services.profiles", %{})),
        allow_redirects: setting("external_services.allow_redirects", false),
        retry_policy: setting("external_services.retry_policy", "none"),
        max_response_bytes: setting("external_services.max_response_bytes", nil)
      },
      package_installs: %{
        enabled: setting("package_installs.enabled", false),
        allowed_roots_count: length(setting("package_installs.allowed_roots", [])),
        allowed_managers: setting("package_installs.allowed_managers", []),
        lifecycle_scripts_allowed: setting("package_installs.lifecycle_scripts_allowed", false),
        git_dependencies_allowed: setting("package_installs.git_dependencies_allowed", false),
        global_installs_allowed: setting("package_installs.global_installs_allowed", false),
        max_output_bytes: setting("package_installs.max_output_bytes", nil)
      },
      online_skill_import: %{
        enabled: setting("skills.online_import.enabled", false),
        allowed_sources: setting("skills.online_import.allowed_sources", []),
        max_listing_results: setting("skills.online_import.max_listing_results", nil),
        max_download_bytes: setting("skills.online_import.max_download_bytes", nil),
        trust_after_import: setting("skills.online_import.trust_after_import", false)
      },
      plugin_app_registration: %{
        plugins_registration_enabled: setting("plugins.registration_enabled", true),
        app_registry_registration_enabled: setting("app_registry.registration_enabled", true)
      },
      workspace_fragments: %{
        emission_enabled: setting("workspace.fragment.emission_enabled", true),
        rate_limit_per_second: setting("workspace.fragment.rate_limit_per_second", nil),
        receiver_rate_limit_per_second:
          setting("workspace.fragment.receiver_rate_limit_per_second", nil),
        payload_max_bytes: setting("workspace.fragment.payload_max_bytes", nil)
      }
    }
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

  defp setting(key, default) do
    case Settings.get(key) do
      {:ok, value} -> value
      _other -> default
    end
  end
end
