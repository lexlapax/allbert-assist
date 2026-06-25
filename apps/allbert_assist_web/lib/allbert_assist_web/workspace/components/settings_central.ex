defmodule AllbertAssistWeb.Workspace.Components.SettingsCentral do
  @moduledoc """
  Settings Central workspace utility panel.
  """

  use AllbertAssistWeb, :live_component

  alias AllbertAssist.Actions.Helper, as: ActionHelper
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.ExternalRequestMetadata
  alias AllbertAssist.Confirmations.ObjectiveContext
  alias AllbertAssist.Confirmations.OnlineSkillMetadata
  alias AllbertAssist.Confirmations.PackageInstallMetadata
  alias AllbertAssist.Confirmations.ResourceMetadata
  alias AllbertAssist.Confirmations.ShellCommandMetadata
  alias AllbertAssist.Confirmations.SkillScriptMetadata
  alias AllbertAssist.Surfaces.ContextBuilder
  alias AllbertAssist.Theme.Status, as: ThemeStatus

  @default_key "operator.communication_style"

  @impl true
  def update(assigns, socket) do
    selected_key = Map.get(assigns, :selected_key, @default_key)
    context = Map.get(assigns, :renderer_context, %{})
    loaded? = Map.get(socket.assigns, :settings_loaded?, false)
    current_key = Map.get(socket.assigns, :selected_key)

    open? =
      Map.get(socket.assigns, :settings_panel_open?, false) ||
        Map.get(context, :canvas_destination) == "workspace:settings"

    socket =
      socket
      |> assign(assigns)
      |> assign_new(:node, fn -> nil end)
      |> assign_new(:settings_notice, fn -> "" end)
      |> assign_new(:model_doctor_summary, fn -> nil end)
      |> assign_new(:settings_loaded?, fn -> false end)
      |> assign_new(:settings, fn -> [] end)
      |> assign_new(:providers, fn -> [] end)
      |> assign_new(:models, fn -> [] end)
      |> assign_new(:security_status, &empty_security_status/0)
      |> assign_new(:theme_status, &empty_theme_status/0)
      |> assign_new(:pending_confirmations, fn -> [] end)
      |> assign_new(:resolved_confirmations, fn -> [] end)
      |> assign_new(:resource_grants, fn -> [] end)
      |> assign_new(:liveview_confirmation_approval?, fn -> true end)
      |> assign_new(:selected_key, fn -> selected_key end)
      |> assign_new(:selected_value, fn -> "" end)
      |> assign_new(:explanation, fn -> "" end)
      |> assign_new(:diagnostics, fn -> "" end)
      |> assign_new(:last_audit_path, fn -> nil end)
      |> assign_new(:setting_form, fn ->
        to_form(%{"key" => selected_key, "value" => ""}, as: :setting)
      end)
      |> assign_new(:provider_form, fn ->
        to_form(%{"provider" => "openai", "api_key" => ""}, as: :provider)
      end)
      |> assign(:settings_panel_open?, open?)

    if open? and connected?(socket) and (not loaded? or current_key != selected_key) do
      {:ok, refresh(socket, selected_key)}
    else
      {:ok, socket}
    end
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
          |> assign(:settings_notice, "Setting saved.")
          |> assign(:diagnostics, "")
          |> assign(:last_audit_path, action_audit_path(response))
          |> refresh(key)

        {:error, reason} ->
          socket
          |> assign(:settings_notice, "")
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
          |> assign(:settings_notice, "Permission setting saved.")
          |> assign(:diagnostics, "")
          |> assign(:last_audit_path, action_audit_path(response))
          |> refresh(key)

        {:error, reason} ->
          socket
          |> assign(:settings_notice, "")
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
          |> assign(:settings_notice, "Provider credential saved.")
          |> assign(:diagnostics, "")
          |> assign(:last_audit_path, action_audit_path(response))
          |> refresh(socket.assigns.selected_key)

        {:error, reason} ->
          socket
          |> assign(:settings_notice, "")
          |> assign(:diagnostics, inspect(reason))
          |> refresh_forms(socket.assigns.selected_key, socket.assigns.selected_value)
      end

    {:noreply, socket}
  end

  def handle_event("use_model_profile", %{"profile" => profile}, socket) do
    socket =
      case completed_action("set_active_model_profile", %{profile: profile}) do
        {:ok, response} ->
          socket
          |> assign(:settings_notice, "Model profile saved.")
          |> assign(:diagnostics, "")
          |> assign(:last_audit_path, action_audit_path(response))
          |> refresh(socket.assigns.selected_key)

        {:error, reason} ->
          socket
          |> assign(:settings_notice, "")
          |> assign(:diagnostics, inspect(reason))
          |> refresh_forms(socket.assigns.selected_key, socket.assigns.selected_value)
      end

    {:noreply, socket}
  end

  def handle_event("doctor_model_profile", %{"profile" => profile}, socket) do
    socket =
      case completed_action("doctor_model_profile", %{profile: profile}) do
        {:ok, response} ->
          socket
          |> assign(:settings_notice, "Model doctor completed.")
          |> assign(:diagnostics, "")
          |> refresh(socket.assigns.selected_key)
          |> assign(:model_doctor_summary, response.doctor)

        {:error, reason} ->
          socket
          |> assign(:settings_notice, "")
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
          |> assign(:settings_notice, confirmation_flash_message(response.confirmation))
          |> assign(:diagnostics, "")
          |> refresh(socket.assigns.selected_key)

        {:error, reason} ->
          socket
          |> assign(:settings_notice, "")
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
          |> assign(:settings_notice, confirmation_flash_message(response.confirmation))
          |> assign(:diagnostics, "")
          |> refresh(socket.assigns.selected_key)

        {:error, reason} ->
          socket
          |> assign(:settings_notice, "")
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
          |> assign(:settings_notice, "Confirmation #{response.confirmation["status"]}.")
          |> assign(:diagnostics, "")
          |> refresh(socket.assigns.selected_key)

        {:error, reason} ->
          socket
          |> assign(:settings_notice, "")
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
          |> assign(:settings_notice, "Resource grant revoked.")
          |> assign(:diagnostics, "")
          |> refresh(socket.assigns.selected_key)

        {:error, reason} ->
          socket
          |> assign(:settings_notice, "")
          |> assign(:diagnostics, inspect(reason))
          |> refresh(socket.assigns.selected_key)
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id="workspace-settings-panel"
      class="workspace-settings-panel"
      data-workspace-component="settings_panel"
      data-workspace-renderer="component"
      aria-labelledby="workspace-settings-panel-title"
    >
      <header class="workspace-settings-panel-header">
        <h2 id="workspace-settings-panel-title" class="workspace-rail-title">Settings Central</h2>
      </header>

      <p :if={@settings_notice != ""} id="settings-notice" class="text-sm text-success">
        {@settings_notice}
      </p>

      <div :if={!@settings_panel_open?} class="workspace-settings-panel-preview">
        <p class="text-sm text-base-content/60">
          Settings, provider keys, confirmations, and grants.
        </p>
        <a
          id="workspace-settings-open"
          class="workspace-utility-link"
          href={workspace_settings_path(@renderer_context)}
        >
          <.icon name="hero-adjustments-horizontal-micro" class="size-4" /> Open settings
        </a>
      </div>

      <div :if={@settings_panel_open?} class="workspace-settings-panel-body">
        <div class="grid gap-6">
          <section id="settings-list" class="space-y-2">
            <button
              :for={setting <- @settings}
              type="button"
              phx-click="select_setting"
              phx-target={@myself}
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
                phx-target={@myself}
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

            <section id="workspace-theme-diagnostics" class="space-y-3">
              <h2 class="text-lg font-medium">Workspace Appearance</h2>
              <div class="grid gap-3 md:grid-cols-3">
                <div
                  id="workspace-theme-token-status"
                  class="rounded border border-base-300 p-3 text-sm"
                >
                  <h3 class="font-medium">Token Theme</h3>
                  <div>File: {status_value(@theme_status.token.basename)}</div>
                  <div>Status: {@theme_status.token.status}</div>
                  <div>Fingerprint: {status_value(@theme_status.token.fingerprint)}</div>
                  <div>Modified: {status_value(@theme_status.token.mtime)}</div>
                </div>

                <div
                  id="workspace-theme-snippet-status"
                  class="rounded border border-base-300 p-3 text-sm"
                >
                  <h3 class="font-medium">Snippets</h3>
                  <div>Enabled: {inspect(@theme_status.snippets.enabled?)}</div>
                  <div>Status: {@theme_status.snippets.status}</div>
                  <div :for={snippet <- @theme_status.snippets.items}>
                    {status_value(snippet.basename)}: {snippet.status} {status_value(
                      snippet.fingerprint
                    )}
                  </div>
                </div>

                <div id="workspace-layout-status" class="rounded border border-base-300 p-3 text-sm">
                  <h3 class="font-medium">Layout</h3>
                  <div>Enabled: {inspect(@theme_status.layout.enabled?)}</div>
                  <div>File: {@theme_status.layout.basename}</div>
                  <div>Status: {@theme_status.layout.status}</div>
                  <div>Fingerprint: {status_value(@theme_status.layout.fingerprint)}</div>
                  <div>Modified: {status_value(@theme_status.layout.mtime)}</div>
                </div>
              </div>

              <div
                :if={@theme_status.diagnostics != []}
                id="workspace-theme-diagnostics-list"
                class="rounded border border-base-300 p-3 text-sm"
              >
                <div :for={diagnostic <- @theme_status.diagnostics}>{diagnostic}</div>
              </div>
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
                      phx-target={@myself}
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
                        phx-target={@myself}
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
                        phx-target={@myself}
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
                        phx-target={@myself}
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
                        phx-target={@myself}
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
                    phx-target={@myself}
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
                <div>Endpoint: {provider.endpoint_kind}</div>
                <div>Enabled: {inspect(provider.enabled)}</div>
                <div>Credential: {provider.credential_status}</div>
              </div>
            </section>

            <section id="model-profiles" class="space-y-2">
              <h2 class="text-lg font-medium">Models</h2>
              <div :for={model <- @models} class="rounded border border-base-300 p-3 text-sm">
                <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
                  <div class="min-w-0">
                    <div class="font-medium">{model.name}</div>
                    <div>Provider: {model.provider}</div>
                    <div>Endpoint: {model.provider_endpoint_kind}</div>
                    <div>Model: {model.model}</div>
                    <div>Credential: {model.credential_status}</div>
                  </div>

                  <div class="flex flex-wrap gap-2">
                    <button
                      id={"doctor-model-#{model.name}"}
                      type="button"
                      phx-click="doctor_model_profile"
                      phx-target={@myself}
                      phx-value-profile={model.name}
                      class="btn btn-secondary btn-sm"
                    >
                      Doctor
                    </button>
                    <button
                      id={"use-model-#{model.name}"}
                      type="button"
                      phx-click="use_model_profile"
                      phx-target={@myself}
                      phx-value-profile={model.name}
                      class="btn btn-primary btn-sm"
                    >
                      Use
                    </button>
                  </div>
                </div>
              </div>

              <div
                :if={@model_doctor_summary}
                id="model-doctor-summary"
                class="rounded border border-base-300 p-3 text-sm"
              >
                <div class="font-medium">Last doctor</div>
                <div>Endpoint: {@model_doctor_summary.endpoint_kind}</div>
                <div>Host: {@model_doctor_summary.redacted_host}</div>
                <div>Endpoint OK: {inspect(@model_doctor_summary.endpoint_ok)}</div>
                <div>Credential OK: {inspect(@model_doctor_summary.credential_ok)}</div>
                <div>Model available: {inspect(@model_doctor_summary.model_available)}</div>
                <div :for={diagnostic <- @model_doctor_summary.diagnostics}>
                  {diagnostic.code}: {diagnostic.message}
                </div>
              </div>
            </section>

            <section>
              <.form
                for={@provider_form}
                id="provider-key-form"
                phx-submit="save_provider_key"
                phx-target={@myself}
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
    </section>
    """
  end

  defp empty_security_status do
    %{
      permission_defaults: [],
      safety_floors: [],
      skill_trust: %{
        configured_settings: 0,
        enabled_count: 0,
        disabled_count: 0,
        trusted_project_roots_count: 0
      },
      capability_boundaries: %{
        external_services: %{
          enabled: false,
          allowed_hosts_count: 0,
          profiles_count: 0,
          retry_policy: "none"
        },
        package_installs: %{
          enabled: false,
          allowed_managers: [],
          allowed_roots_count: 0,
          lifecycle_scripts_allowed: false
        },
        online_skill_import: %{
          enabled: false,
          allowed_sources: [],
          trust_after_import: false
        }
      },
      secret_status: %{providers: 0, configured: 0, missing: 0},
      redaction_posture: %{secret_ref_display: "[SECRET_REF]", surfaces: []},
      future_boundaries: []
    }
  end

  defp empty_theme_status do
    %{
      token: %{basename: "none", status: "loading", fingerprint: nil, mtime: nil},
      snippets: %{enabled?: false, status: "loading", items: []},
      layout: %{
        enabled?: false,
        basename: "layout.yaml",
        status: "loading",
        fingerprint: nil,
        mtime: nil
      },
      diagnostics: []
    }
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
    |> assign(:settings_loaded?, true)
    |> assign(:providers, providers)
    |> assign(:models, models)
    |> assign(:security_status, security_status)
    |> assign(:theme_status, ThemeStatus.summary())
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
    |> assign_new(:settings_notice, fn -> "" end)
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

  defp status_value(nil), do: "none"
  defp status_value(value), do: to_string(value)

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
    ActionHelper.completed_action(action_name, params, context())
  end

  defp action_audit_path(response) do
    response
    |> Map.get(:actions, [])
    |> Enum.find_value(&get_in(&1, [:settings_metadata, :audit_path]))
  end

  defp context do
    ContextBuilder.live_view_context(%{}, surface: "/workspace")
  end

  defp workspace_settings_path(context) do
    params =
      [
        destination: "workspace:settings",
        tab: "canvas"
      ]
      |> maybe_put_param(:thread_id, Map.get(context, :thread_id))

    ~p"/workspace?#{params}"
  end

  defp maybe_put_param(params, _key, value) when value in [nil, ""], do: params
  defp maybe_put_param(params, key, value), do: Keyword.put(params, key, value)

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
