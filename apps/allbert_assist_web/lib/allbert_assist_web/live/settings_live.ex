defmodule AllbertAssistWeb.SettingsLive do
  @moduledoc """
  Operator Settings Central surface.
  """

  use AllbertAssistWeb, :live_view

  alias AllbertAssist.Actions.Runner

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

    settings = settings_response.settings
    providers = providers_response.providers
    models = models_response.models

    setting = Enum.find(settings, &(&1.key == selected_key)) || List.first(settings)

    socket
    |> assign(:settings, settings)
    |> assign(:providers, providers)
    |> assign(:models, models)
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

  defp completed_action(action_name, params) do
    case Runner.run(action_name, params, context()) do
      {:ok, %{status: :completed} = response} -> {:ok, response}
      {:ok, response} -> {:error, response_error(response)}
    end
  end

  defp response_error(%{error: error}), do: error

  defp response_error(%{actions: actions, message: message}) when is_list(actions) do
    actions
    |> Enum.find_value(&get_in(&1, [:settings_metadata, :error]))
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
    %{actor: "local", channel: :live_view}
  end
end
