defmodule AllbertAssistWeb.SettingsLive do
  @moduledoc """
  Operator Settings Central surface.
  """

  use AllbertAssistWeb, :live_view

  alias AllbertAssist.{Actions.Runner, Confirmations}
  alias AllbertAssist.Confirmations.ExternalRequestMetadata
  alias AllbertAssist.Confirmations.ObjectiveContext
  alias AllbertAssist.Confirmations.OnlineSkillMetadata
  alias AllbertAssist.Confirmations.PackageInstallMetadata
  alias AllbertAssist.Confirmations.ResourceMetadata
  alias AllbertAssist.Confirmations.ShellCommandMetadata
  alias AllbertAssist.Confirmations.SkillScriptMetadata

  @default_key "operator.communication_style"

  @impl true
  def mount(_params, _session, socket) do
    {:ok, refresh(socket, @default_key)}
  end

  @impl true
  def handle_event("select_setting", %{"key" => key}, socket) do
    {:noreply, refresh(socket, key)}
  end

  def handle_event("save_setting", %{"setting" => %{"key" => key, "value" => value}}, socket) do
    socket =
      case completed_action("update_setting", %{key: key, value: value}) do
        {:ok, response} ->
          socket
          |> put_flash(:info, "Setting saved.")
          |> assign(:diagnostics, "")
          |> assign(:last_audit_path, action_audit_path(response))
          |> refresh(key)

        {:error, reason} ->
          socket
          |> assign(:diagnostics, inspect(reason))
          |> refresh_forms(key, value)
      end

    {:noreply, socket}
  end

  def handle_event(
        "save_permission_setting",
        %{"permission" => %{"key" => key, "value" => value}},
        socket
      ) do
    socket =
      case completed_action("update_setting", %{key: key, value: value}) do
        {:ok, response} ->
          socket
          |> put_flash(:info, "Permission setting saved.")
          |> assign(:diagnostics, "")
          |> assign(:last_audit_path, action_audit_path(response))
          |> refresh(key)

        {:error, reason} ->
          socket
          |> assign(:diagnostics, inspect(reason))
          |> refresh(socket.assigns.selected_key)
      end

    {:noreply, socket}
  end

  def handle_event(
        "save_provider_key",
        %{"provider" => %{"provider" => provider, "api_key" => api_key}},
        socket
      ) do
    socket =
      case completed_action("set_provider_credential", %{
             provider: provider,
             mode: :set_secret,
             api_key: api_key
           }) do
        {:ok, response} ->
          socket
          |> put_flash(:info, "Provider credential saved.")
          |> assign(:diagnostics, "")
          |> assign(:last_audit_path, action_audit_path(response))
          |> refresh(socket.assigns.selected_key)

        {:error, reason} ->
          socket
          |> assign(:diagnostics, inspect(reason))
          |> refresh_forms(socket.assigns.selected_key, socket.assigns.selected_value)
      end

    {:noreply, socket}
  end

  def handle_event("approve_confirmation", %{"id" => id}, socket) do
    socket =
      case completed_action("approve_confirmation", %{id: id}) do
        {:ok, response} ->
          socket
          |> put_flash(:info, confirmation_flash_message(response.confirmation))
          |> assign(:diagnostics, "")
          |> refresh(socket.assigns.selected_key)

        {:error, reason} ->
          socket
          |> assign(:diagnostics, inspect(reason))
          |> refresh(socket.assigns.selected_key)
      end

    {:noreply, socket}
  end

  def handle_event(
        "approve_confirmation_remember",
        %{"id" => id, "scope" => scope} = params,
        socket
      ) do
    approve_params =
      %{id: id, remember_scope: scope}
      |> maybe_put(:resource_index, parse_non_negative_integer(Map.get(params, "resource-index")))
      |> maybe_put(:remember_all, truthy?(Map.get(params, "remember-all")))

    socket =
      case completed_action("approve_confirmation", approve_params) do
        {:ok, response} ->
          socket
          |> put_flash(:info, confirmation_flash_message(response.confirmation))
          |> assign(:diagnostics, "")
          |> refresh(socket.assigns.selected_key)

        {:error, reason} ->
          socket
          |> assign(:diagnostics, inspect(reason))
          |> refresh(socket.assigns.selected_key)
      end

    {:noreply, socket}
  end

  def handle_event(
        "deny_confirmation",
        %{"confirmation" => %{"id" => id, "reason" => reason}},
        socket
      ) do
    params = %{id: id} |> maybe_put(:reason, blank_to_nil(reason))

    socket =
      case completed_action("deny_confirmation", params) do
        {:ok, response} ->
          socket
          |> put_flash(:info, "Confirmation #{response.confirmation["status"]}.")
          |> assign(:diagnostics, "")
          |> refresh(socket.assigns.selected_key)

        {:error, reason} ->
          socket
          |> assign(:diagnostics, inspect(reason))
          |> refresh(socket.assigns.selected_key)
      end

    {:noreply, socket}
  end

  def handle_event("revoke_resource_grant", %{"id" => id}, socket) do
    socket =
      case completed_action("revoke_resource_grant", %{
             id: id,
             reason: "Revoked from /workspace"
           }) do
        {:ok, _response} ->
          socket
          |> put_flash(:info, "Resource grant revoked.")
          |> assign(:diagnostics, "")
          |> refresh(socket.assigns.selected_key)

        {:error, reason} ->
          socket
          |> assign(:diagnostics, inspect(reason))
          |> refresh(socket.assigns.selected_key)
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-6xl px-6 py-8">
        <header class="mb-6">
          <h1 class="text-2xl font-semibold">Settings Central</h1>
        </header>

        <div class="grid gap-6 lg:grid-cols-[minmax(220px,320px)_1fr]">
          <section id="settings-list" class="space-y-2">
            <button
              :for={setting <- @settings}
              type="button"
              phx-click="select_setting"
              phx-value-key={setting.key}
              class={[
                "block w-full rounded border px-3 py-2 text-left text-sm transition",
                setting.key == @selected_key && "border-blue-500 bg-blue-50",
                setting.key != @selected_key && "border-base-300 hover:border-base-content/40"
              ]}
            >
              <span class="block font-medium">{setting.key}</span>
              <span class="text-xs text-base-content/60">{setting.source}</span>
            </button>
          </section>

          <main class="space-y-6">
            <section>
              <.form
                for={@setting_form}
                id="settings-form"
                phx-submit="save_setting"
                class="space-y-3"
              >
                <.input field={@setting_form[:key]} id="settings-key" type="text" label="Key" />
                <.input field={@setting_form[:value]} id="settings-value" type="text" label="Value" />
                <button id="settings-save" type="submit" class="btn btn-primary">Save</button>
              </.form>

              <pre
                id="settings-explanation"
                class="mt-4 whitespace-pre-wrap rounded border border-base-300 p-3 text-sm"
              >{@explanation}</pre>
              <p id="settings-diagnostics" class="mt-3 text-sm text-error">{@diagnostics}</p>
              <p :if={@last_audit_path} id="settings-audit" class="mt-2 text-xs text-base-content/60">
                Audit: {@last_audit_path}
              </p>
            </section>

            <section id="security-status" class="space-y-4">
              <div>
                <h2 class="text-lg font-medium">Security & Permissions</h2>
                <p class="text-sm text-base-content/60">
                  Settings Central stores editable permission policy. Security Central shows the effective decision after safety floors.
                </p>
              </div>

              <div id="security-permission-defaults" class="space-y-3">
                <div
                  :for={policy <- @security_status.permission_defaults}
                  id={"security-permission-#{permission_dom_id(policy.permission)}"}
                  class="rounded border border-base-300 p-3 text-sm"
                >
                  <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                    <div>
                      <div class="font-medium">{policy.permission}</div>
                      <div class="text-xs text-base-content/60">
                        Effective: {policy.effective} · Source: {policy.source} · Capped: {inspect(
                          policy.capped?
                        )}
                      </div>
                      <div class="text-xs text-base-content/60">{policy.reason}</div>
                    </div>

                    <.form
                      :if={policy.setting_key}
                      for={permission_form(policy)}
                      id={"permission-#{permission_dom_id(policy.permission)}-form"}
                      phx-submit="save_permission_setting"
                      class="flex items-center gap-2"
                    >
                      <input type="hidden" name="permission[key]" value={policy.setting_key} />
                      <select
                        id={"permission-#{permission_dom_id(policy.permission)}-value"}
                        name="permission[value]"
                        class="select select-bordered select-sm"
                      >
                        <option
                          :for={option <- permission_options(policy)}
                          value={option}
                          selected={option == permission_selected_value(policy)}
                        >
                          {option}
                        </option>
                      </select>
                      <button
                        id={"permission-#{permission_dom_id(policy.permission)}-save"}
                        type="submit"
                        class="btn btn-secondary btn-sm"
                      >
                        Save
                      </button>
                    </.form>

                    <span :if={!policy.setting_key} class="text-xs text-base-content/60">
                      Built-in
                    </span>
                  </div>
                </div>
              </div>

              <div id="security-safety-floors" class="rounded border border-base-300 p-3 text-sm">
                <h3 class="font-medium">Safety Floors</h3>
                <div :for={floor <- @security_status.safety_floors}>
                  {floor.permission}: {floor.floor}
                </div>
              </div>

              <div
                id="security-skill-trust-summary"
                class="rounded border border-base-300 p-3 text-sm"
              >
                <h3 class="font-medium">Skill Trust</h3>
                <div>Configured settings: {@security_status.skill_trust.configured_settings}</div>
                <div>Enabled: {@security_status.skill_trust.enabled_count}</div>
                <div>Disabled: {@security_status.skill_trust.disabled_count}</div>
                <div>
                  Trusted project roots: {@security_status.skill_trust.trusted_project_roots_count}
                </div>
              </div>

              <div
                id="security-execution-capabilities"
                class="rounded border border-base-300 p-3 text-sm"
              >
                <h3 class="font-medium">Execution Capabilities</h3>
                <div>
                  External services: {@security_status.capability_boundaries.external_services.enabled} · hosts {@security_status.capability_boundaries.external_services.allowed_hosts_count} · profiles {@security_status.capability_boundaries.external_services.profiles_count} · retry {@security_status.capability_boundaries.external_services.retry_policy}
                </div>
                <div>
                  Package installs: {@security_status.capability_boundaries.package_installs.enabled} · managers {Enum.join(
                    @security_status.capability_boundaries.package_installs.allowed_managers,
                    ", "
                  )} · roots {@security_status.capability_boundaries.package_installs.allowed_roots_count} · lifecycle scripts {@security_status.capability_boundaries.package_installs.lifecycle_scripts_allowed}
                </div>
                <div>
                  Online skill import: {@security_status.capability_boundaries.online_skill_import.enabled} · sources {Enum.join(
                    @security_status.capability_boundaries.online_skill_import.allowed_sources,
                    ", "
                  )} · trust after import {@security_status.capability_boundaries.online_skill_import.trust_after_import}
                </div>
              </div>

              <div id="security-secret-status" class="rounded border border-base-300 p-3 text-sm">
                <h3 class="font-medium">Secrets</h3>
                <div>Providers: {@security_status.secret_status.providers}</div>
                <div>Configured: {@security_status.secret_status.configured}</div>
                <div>Missing: {@security_status.secret_status.missing}</div>
              </div>

              <div
                id="security-redaction-posture"
                class="rounded border border-base-300 p-3 text-sm"
              >
                <h3 class="font-medium">Redaction</h3>
                <div>
                  Secret refs display as {@security_status.redaction_posture.secret_ref_display}
                </div>
                <div>Surfaces: {Enum.join(@security_status.redaction_posture.surfaces, ", ")}</div>
              </div>

              <div id="security-future-boundaries" class="rounded border border-base-300 p-3 text-sm">
                <h3 class="font-medium">Future Boundaries</h3>
                <div :for={boundary <- @security_status.future_boundaries}>
                  {boundary.name}: {boundary.milestone} {boundary.status}
                </div>
              </div>
            </section>

            <section id="confirmation-requests" class="space-y-4">
              <div class="flex items-center justify-between gap-3">
                <h2 class="text-lg font-medium">Confirmation Requests</h2>
                <span id="pending-confirmation-count" class="text-sm text-base-content/60">
                  Pending: {length(@pending_confirmations)}
                </span>
              </div>

              <div id="pending-confirmations" class="space-y-3">
                <p
                  :if={@pending_confirmations == []}
                  id="no-pending-confirmations"
                  class="rounded border border-base-300 p-3 text-sm text-base-content/60"
                >
                  No pending confirmations.
                </p>

                <div
                  :for={confirmation <- @pending_confirmations}
                  id={"confirmation-pending-#{confirmation["id"]}"}
                  class="rounded border border-base-300 p-3 text-sm"
                >
                  <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
                    <div class="min-w-0 space-y-1">
                      <div class="font-medium">{target_name(confirmation)}</div>
                      <div class="text-xs text-base-content/60">
                        {confirmation["id"]} · {confirmation["status"]} · {confirmation[
                          "target_permission"
                        ]} · risk {risk_tier(confirmation)}
                      </div>
                      <div class="text-xs text-base-content/60">
                        Origin: {origin_text(confirmation)} · Expires: {confirmation["expires_at"]}
                      </div>
                      <div
                        :if={selected_skill_name(confirmation)}
                        class="text-xs text-base-content/60"
                      >
                        Skill: {selected_skill_name(confirmation)}
                      </div>
                      <div
                        :if={confirmation_detail_lines(confirmation) != []}
                        id={"confirmation-details-#{confirmation["id"]}"}
                        class="text-xs text-base-content/70"
                      >
                        <div :for={line <- confirmation_detail_lines(confirmation)}>{line}</div>
                      </div>
                    </div>

                    <div class="flex flex-col gap-2 sm:flex-row">
                      <button
                        id={"approve-confirmation-#{confirmation["id"]}"}
                        type="button"
                        phx-click="approve_confirmation"
                        phx-value-id={confirmation["id"]}
                        class="btn btn-primary btn-sm"
                        disabled={!@liveview_confirmation_approval?}
                      >
                        Approve
                      </button>

                      <button
                        :if={resource_ref_count(confirmation) > 0}
                        id={"approve-confirmation-#{confirmation["id"]}-remember-exact"}
                        type="button"
                        phx-click="approve_confirmation_remember"
                        phx-value-id={confirmation["id"]}
                        phx-value-scope="exact"
                        phx-value-resource-index="0"
                        class="btn btn-secondary btn-sm"
                        disabled={!@liveview_confirmation_approval?}
                      >
                        Approve + remember
                      </button>

                      <button
                        :if={resource_ref_count(confirmation) > 1}
                        id={"approve-confirmation-#{confirmation["id"]}-remember-all"}
                        type="button"
                        phx-click="approve_confirmation_remember"
                        phx-value-id={confirmation["id"]}
                        phx-value-scope="exact"
                        phx-value-remember-all="true"
                        class="btn btn-secondary btn-sm"
                        disabled={!@liveview_confirmation_approval?}
                      >
                        Approve + remember all
                      </button>

                      <.form
                        for={confirmation_form(confirmation)}
                        id={"deny-confirmation-#{confirmation["id"]}-form"}
                        phx-submit="deny_confirmation"
                        class="flex gap-2"
                      >
                        <input type="hidden" name="confirmation[id]" value={confirmation["id"]} />
                        <input
                          id={"deny-confirmation-#{confirmation["id"]}-reason"}
                          name="confirmation[reason]"
                          type="text"
                          class="input input-bordered input-sm w-36"
                          placeholder="Reason"
                        />
                        <button
                          id={"deny-confirmation-#{confirmation["id"]}"}
                          type="submit"
                          class="btn btn-secondary btn-sm"
                        >
                          Deny
                        </button>
                      </.form>
                    </div>
                  </div>

                  <pre
                    id={"confirmation-params-#{confirmation["id"]}"}
                    class="mt-3 max-h-32 overflow-auto rounded bg-base-200 p-2 text-xs"
                  ><%= params_summary(confirmation) %></pre>
                </div>
              </div>

              <div id="resolved-confirmations" class="space-y-2">
                <h3 class="text-sm font-medium">Recently Resolved</h3>
                <p
                  :if={@resolved_confirmations == []}
                  id="no-resolved-confirmations"
                  class="rounded border border-base-300 p-3 text-sm text-base-content/60"
                >
                  No resolved confirmations.
                </p>
                <div
                  :for={confirmation <- @resolved_confirmations}
                  id={"confirmation-resolved-#{confirmation["id"]}"}
                  class="rounded border border-base-300 p-3 text-sm"
                >
                  <div class="font-medium">{target_name(confirmation)}</div>
                  <div class="text-xs text-base-content/60">
                    {confirmation["id"]} · status {confirmation["status"]} · resolver {resolver_text(
                      confirmation
                    )}
                  </div>
                  <div
                    :if={status_note(confirmation)}
                    class="mt-1 text-xs text-base-content/70"
                  >
                    {status_note(confirmation)}
                  </div>
                  <div
                    :if={confirmation_detail_lines(confirmation) != []}
                    id={"confirmation-result-#{confirmation["id"]}"}
                    class="mt-2 text-xs text-base-content/70"
                  >
                    <div :for={line <- confirmation_detail_lines(confirmation)}>{line}</div>
                  </div>
                </div>
              </div>
            </section>

            <section id="remembered-resource-grants" class="space-y-4">
              <div class="flex items-center justify-between gap-3">
                <h2 class="text-lg font-medium">Remembered Resource Grants</h2>
                <span id="resource-grant-count" class="text-sm text-base-content/60">
                  Active: {active_resource_grant_count(@resource_grants)} · Total: {length(
                    @resource_grants
                  )}
                </span>
              </div>

              <p
                :if={@resource_grants == []}
                id="no-resource-grants"
                class="rounded border border-base-300 p-3 text-sm text-base-content/60"
              >
                No remembered resource grants.
              </p>

              <div
                :for={grant <- @resource_grants}
                id={"resource-grant-#{grant["id"]}"}
                class="rounded border border-base-300 p-3 text-sm"
              >
                <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
                  <div class="min-w-0 space-y-1">
                    <div class="font-medium">{grant["operation_class"]}</div>
                    <div class="text-xs text-base-content/60">
                      {grant["id"]} · {grant_status(grant)} · {grant["access_mode"]} · {Map.get(
                        grant,
                        "downstream_consumer",
                        "none"
                      )}
                    </div>
                    <div class="text-xs text-base-content/70">
                      {resource_grant_scope_text(grant)}
                    </div>
                    <div class="text-xs text-base-content/60">
                      Created: {grant["created_at"]} · Expires: {Map.get(
                        grant,
                        "expires_at",
                        "none"
                      )}
                    </div>
                  </div>

                  <button
                    id={"revoke-resource-grant-#{grant["id"]}"}
                    type="button"
                    phx-click="revoke_resource_grant"
                    phx-value-id={grant["id"]}
                    class="btn btn-secondary btn-sm"
                    disabled={grant_status(grant) == "revoked"}
                  >
                    Revoke
                  </button>
                </div>
              </div>
            </section>

            <section id="provider-profiles" class="space-y-2">
              <h2 class="text-lg font-medium">Providers</h2>
              <div :for={provider <- @providers} class="rounded border border-base-300 p-3 text-sm">
                <div class="font-medium">{provider.name}</div>
                <div>Type: {provider.type}</div>
                <div>Enabled: {inspect(provider.enabled)}</div>
                <div>Credential: {provider.credential_status}</div>
              </div>
            </section>

            <section id="model-profiles" class="space-y-2">
              <h2 class="text-lg font-medium">Models</h2>
              <div :for={model <- @models} class="rounded border border-base-300 p-3 text-sm">
                <div class="font-medium">{model.name}</div>
                <div>Provider: {model.provider}</div>
                <div>Model: {model.model}</div>
                <div>Credential: {model.credential_status}</div>
              </div>
            </section>

            <section>
              <.form
                for={@provider_form}
                id="provider-key-form"
                phx-submit="save_provider_key"
                class="space-y-3"
              >
                <.input field={@provider_form[:provider]} type="text" label="Provider" />
                <.input field={@provider_form[:api_key]} type="password" label="API key" />
                <button type="submit" class="btn btn-secondary">Set Provider Key</button>
              </.form>
            </section>
          </main>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp refresh(socket, selected_key) do
    {:ok, settings_response} = completed_action("list_settings", %{})
    {:ok, providers_response} = completed_action("list_provider_profiles", %{})
    {:ok, models_response} = completed_action("list_model_profiles", %{})
    {:ok, security_response} = completed_action("security_status", %{})
    {:ok, pending_response} = completed_action("list_confirmations", %{status: "pending"})
    {:ok, resolved_response} = completed_action("list_confirmations", %{status: "resolved"})
    {:ok, resource_grants_response} = completed_action("list_resource_grants", %{})

    settings = settings_response.settings
    providers = providers_response.providers
    models = models_response.models
    security_status = security_response.security_status

    setting = Enum.find(settings, &(&1.key == selected_key)) || List.first(settings)

    socket
    |> assign(:settings, settings)
    |> assign(:providers, providers)
    |> assign(:models, models)
    |> assign(:security_status, security_status)
    |> assign(:pending_confirmations, pending_response.confirmations)
    |> assign(:resolved_confirmations, recently_resolved(resolved_response.confirmations))
    |> assign(:resource_grants, resource_grants_response.grants)
    |> assign(
      :liveview_confirmation_approval?,
      setting_bool(settings, "confirmations.allow_liveview_approval", true)
    )
    |> assign(:selected_key, setting.key)
    |> assign(:selected_value, setting.value)
    |> assign(:explanation, explanation(setting))
    |> assign_new(:diagnostics, fn -> "" end)
    |> assign_new(:last_audit_path, fn -> nil end)
    |> refresh_forms(setting.key, setting.value)
  end

  defp refresh_forms(socket, key, value) do
    socket
    |> assign(:setting_form, to_form(%{"key" => key, "value" => form_value(value)}, as: :setting))
    |> assign(:provider_form, to_form(%{"provider" => "openai", "api_key" => ""}, as: :provider))
  end

  defp explanation(setting) do
    layers =
      setting.layers
      |> Enum.map(&"- #{&1.source}: #{inspect(&1.value)}")
      |> Enum.join("\n")

    """
    #{setting.key}
    Value: #{inspect(setting.value)}
    Source: #{setting.source}
    Writable: #{setting.writable?}

    Layers:
    #{layers}
    """
    |> String.trim()
  end

  defp form_value(value) when is_binary(value), do: value
  defp form_value(value), do: inspect(value)

  defp permission_form(policy) do
    to_form(
      %{
        "key" => policy.setting_key,
        "value" => permission_selected_value(policy)
      },
      as: :permission
    )
  end

  defp permission_selected_value(%{configured: configured}) when is_binary(configured),
    do: configured

  defp permission_selected_value(%{configured_decision: :allowed}), do: "allowed"

  defp permission_selected_value(%{configured_decision: :needs_confirmation}),
    do: "needs_confirmation"

  defp permission_selected_value(%{configured_decision: :denied}), do: "denied"
  defp permission_selected_value(_policy), do: "denied"

  defp permission_options(%{permission: :settings_write}) do
    ["allowed_safe_keys", "needs_confirmation", "denied"]
  end

  defp permission_options(%{setting_key: nil}), do: []
  defp permission_options(_policy), do: ["allowed", "needs_confirmation", "denied"]

  defp permission_dom_id(permission) do
    permission
    |> to_string()
    |> String.replace("_", "-")
  end

  defp completed_action(action_name, params) do
    case Runner.run(action_name, params, context()) do
      {:ok, %{status: :completed} = response} -> {:ok, response}
      {:ok, response} -> {:error, response_error(response)}
    end
  end

  defp response_error(%{error: error}), do: error

  defp response_error(%{actions: actions, message: message}) when is_list(actions) do
    actions
    |> Enum.find_value(fn action ->
      get_in(action, [:settings_metadata, :error]) ||
        get_in(action, [:confirmation_metadata, :error])
    end)
    |> case do
      nil -> message
      error -> error
    end
  end

  defp response_error(%{message: message}), do: message

  defp action_audit_path(response) do
    response
    |> Map.get(:actions, [])
    |> Enum.find_value(&get_in(&1, [:settings_metadata, :audit_path]))
  end

  defp context do
    %{actor: "local", channel: :live_view, surface: "/workspace"}
  end

  defp confirmation_form(confirmation) do
    to_form(%{"id" => confirmation["id"], "reason" => ""}, as: :confirmation)
  end

  defp target_name(confirmation) do
    get_in(confirmation, ["target_action", "name"]) || "unknown"
  end

  defp origin_text(confirmation) do
    origin = Map.get(confirmation, "origin", %{})
    "#{Map.get(origin, "actor", "local")}/#{Map.get(origin, "channel", "unknown")}"
  end

  defp resolver_text(confirmation) do
    resolution = Map.get(confirmation, "operator_resolution", %{}) || %{}

    "#{Map.get(resolution, "resolver_actor", "none")}/#{Map.get(resolution, "resolver_channel", "none")}"
  end

  defp status_note(confirmation), do: Confirmations.status_note(confirmation)

  defp confirmation_flash_message(confirmation) do
    details =
      ExternalRequestMetadata.result_details(confirmation) ++
        ShellCommandMetadata.result_details(confirmation) ++
        PackageInstallMetadata.result_details(confirmation) ++
        OnlineSkillMetadata.lines(confirmation) ++
        ResourceMetadata.lines(confirmation) ++
        remembered_grant_lines(confirmation) ++
        SkillScriptMetadata.result_details(confirmation)

    message = Confirmations.status_message(confirmation)

    if details == [], do: message, else: "#{message} #{Enum.join(details, " · ")}"
  end

  defp risk_tier(confirmation) do
    get_in(confirmation, ["security_decision", "risk", "tier"]) || "unknown"
  end

  defp selected_skill_name(confirmation) do
    case get_in(confirmation, ["selected_skill", "name"]) do
      value when is_binary(value) and value not in ["", "nil"] -> value
      _value -> nil
    end
  end

  defp confirmation_detail_lines(confirmation) do
    ObjectiveContext.lines(confirmation) ++
      ExternalRequestMetadata.lines(confirmation) ++
      ShellCommandMetadata.lines(confirmation) ++
      PackageInstallMetadata.lines(confirmation) ++
      OnlineSkillMetadata.lines(confirmation) ++
      ResourceMetadata.lines(confirmation) ++
      remembered_grant_lines(confirmation) ++
      SkillScriptMetadata.lines(confirmation)
  end

  defp params_summary(confirmation) do
    confirmation
    |> Map.get("params_summary", %{})
    |> inspect(pretty: true, limit: 20, printable_limit: 300)
  end

  defp recently_resolved(confirmations) do
    confirmations
    |> Enum.reverse()
    |> Enum.take(5)
  end

  defp setting_bool(settings, key, default) do
    settings
    |> Enum.find(&(&1.key == key))
    |> case do
      %{value: value} when is_boolean(value) -> value
      _setting -> default
    end
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, _key, false), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value

  defp resource_ref_count(confirmation) do
    confirmation
    |> get_in(["params_summary", "resource_refs"])
    |> List.wrap()
    |> Enum.reject(&(&1 in [nil, "", %{}, []]))
    |> length()
  end

  defp remembered_grant_lines(confirmation) do
    confirmation
    |> get_in(["operator_resolution", "remembered_grants"])
    |> List.wrap()
    |> Enum.reject(&(&1 in [nil, "", %{}, []]))
    |> Enum.map(fn grant ->
      "Remembered grant: #{grant["id"]} #{grant["operation_class"]} #{grant["access_mode"]} #{resource_grant_scope_text(grant)}"
    end)
  end

  defp active_resource_grant_count(grants) do
    Enum.count(grants, &(grant_status(&1) == "active"))
  end

  defp grant_status(%{"revoked_at" => revoked_at}) when revoked_at not in [nil, ""],
    do: "revoked"

  defp grant_status(_grant), do: "active"

  defp resource_grant_scope_text(grant) do
    scope = Map.get(grant, "scope", %{}) || %{}
    "#{scope["kind"]}:#{scope["value"]}"
  end

  defp parse_non_negative_integer(nil), do: nil

  defp parse_non_negative_integer(value) do
    case Integer.parse(to_string(value)) do
      {integer, ""} when integer >= 0 -> integer
      _other -> nil
    end
  end

  defp truthy?(value), do: value in [true, "true", "1", 1, "yes"]
end
