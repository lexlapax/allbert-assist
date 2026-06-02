defmodule AllbertAssistWeb.Workspace.Components.TemplateCreate do
  @moduledoc """
  Workspace Create surface for reviewed v0.38 template patterns.

  This LiveComponent renders vetted template previews and calls registered
  template actions for effectful scaffold writes or v0.37 draft creation.
  """

  use AllbertAssistWeb, :live_component

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Marketplace.Templates, as: MarketplaceTemplates
  alias AllbertAssist.Settings
  alias AllbertAssist.Templates
  alias AllbertAssist.Templates.Scaffold

  @default_allowed_patterns ~w[plugin app llm_tool flow objective]

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    enabled? = create_enabled?()
    patterns = visible_patterns()
    marketplace_templates = installed_marketplace_templates()
    selected_pattern_id = selected_pattern_id(socket.assigns, patterns)
    selected_pattern = pattern_by_id(patterns, selected_pattern_id)
    template_params = template_params(socket.assigns, selected_pattern)
    output_mode = output_mode(socket.assigns, selected_pattern)

    preview =
      preview(
        selected_pattern_id,
        template_params,
        output_mode,
        enabled?,
        action_context(socket.assigns)
      )

    {:ok,
     socket
     |> assign(
       enabled?: enabled?,
       patterns: patterns,
       marketplace_templates: marketplace_templates,
       selected_pattern_id: selected_pattern_id,
       selected_pattern: selected_pattern,
       template_params: template_params,
       output_mode: output_mode,
       preview: preview
     )
     |> assign_new(:create_attempt, fn -> nil end)}
  end

  @impl true
  def handle_event("select_template_pattern", %{"pattern" => pattern_id}, socket) do
    pattern_id = normalize_pattern_id(pattern_id)
    pattern = pattern_by_id(socket.assigns.patterns, pattern_id)
    template_params = template_params(%{}, pattern)
    output_mode = output_mode(%{}, pattern)

    {:noreply,
     socket
     |> assign(
       selected_pattern_id: pattern_id,
       selected_pattern: pattern,
       template_params: template_params,
       output_mode: output_mode,
       create_attempt: nil
     )
     |> refresh_preview()}
  end

  def handle_event("change_template_params", %{"template" => params}, socket) do
    params =
      socket.assigns.selected_pattern
      |> parameter_names()
      |> Enum.reduce(%{}, fn name, acc ->
        Map.put(acc, name, Map.get(params, name, ""))
      end)

    {:noreply,
     socket
     |> assign(template_params: params, create_attempt: nil)
     |> refresh_preview()}
  end

  def handle_event("change_template_params", _params, socket), do: {:noreply, socket}

  def handle_event("select_template_mode", %{"mode" => mode}, socket) do
    mode = normalize_mode(mode, socket.assigns.selected_pattern)

    {:noreply,
     socket
     |> assign(output_mode: mode, create_attempt: nil)
     |> refresh_preview()}
  end

  def handle_event("attempt_template_create", _params, socket) do
    {:noreply, assign(socket, :create_attempt, create_attempt(socket))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id="workspace-create-panel"
      class="space-y-5"
      data-workspace-component="template_create_panel"
      data-workspace-renderer="component"
      data-enabled={bool_attribute(@enabled?)}
      aria-labelledby="workspace-create-title"
    >
      <header class="workspace-card-header">
        <span class="workspace-card-icon" aria-hidden="true">
          <.icon name="hero-plus-circle-micro" class="size-4" />
        </span>
        <div class="min-w-0 flex-1">
          <h2 id="workspace-create-title" class="workspace-card-title">Create</h2>
          <p class="workspace-card-summary">Reviewed templates, preview, and validation.</p>
        </div>
        <span class={["workspace-status-pill", status_class(@preview.status)]}>
          {status_label(@preview.status)}
        </span>
      </header>

      <p
        :if={!@enabled?}
        id="workspace-create-disabled"
        class="rounded border border-warning/30 bg-warning/10 p-3 text-sm"
      >
        Template creation is disabled by Settings Central.
      </p>

      <section id="workspace-create-gallery" class="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
        <button
          :for={pattern <- @patterns}
          id={"workspace-create-pattern-#{pattern.id}"}
          type="button"
          class={[
            "rounded border p-3 text-left transition",
            pattern.id == @selected_pattern_id &&
              "workspace-create-pattern-active border-primary bg-primary/10",
            pattern.id != @selected_pattern_id && "border-base-300 hover:border-base-content/40"
          ]}
          phx-click="select_template_pattern"
          phx-target={@myself}
          phx-value-pattern={pattern.id}
          disabled={!@enabled?}
          data-pattern-id={pattern.id}
          data-live-integration={bool_attribute(live_integration?(pattern))}
        >
          <span class="block text-sm font-medium">{pattern.label}</span>
          <span class="mt-1 block text-xs text-base-content/70">{pattern.description}</span>
          <span class="mt-2 flex flex-wrap gap-1">
            <span
              :for={shape <- pattern.target_shapes}
              class="rounded border border-base-300 px-1.5 py-0.5 text-[0.7rem] text-base-content/70"
            >
              {shape}
            </span>
          </span>
        </button>

        <p :if={@patterns == []} class="rounded border border-base-300 p-3 text-sm">
          No template patterns are allowed by Settings Central.
        </p>
      </section>

      <section
        id="workspace-create-marketplace-templates"
        class="space-y-2 rounded border border-base-300 p-3"
        data-installed-count={length(@marketplace_templates)}
      >
        <header class="flex flex-wrap items-center justify-between gap-2">
          <h3 class="text-sm font-medium">Marketplace templates</h3>
          <span class="text-xs text-base-content/60">
            {length(@marketplace_templates)} installed
          </span>
        </header>

        <article
          :for={template <- @marketplace_templates}
          id={"workspace-create-marketplace-template-#{dom_id(template.entry_id)}"}
          class="rounded border border-base-300 bg-base-200/40 p-3"
          data-entry-id={template.entry_id}
          data-pattern-id={template.pattern_id}
          data-install-state={template.install_state}
          data-authority={template.authority}
        >
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div class="min-w-0">
              <h4 class="text-sm font-medium">{template.name}</h4>
              <p class="mt-1 text-xs text-base-content/70">{template.description}</p>
            </div>
            <span class="workspace-status-pill workspace-status-neutral">
              {template.install_state}
            </span>
          </div>

          <div class="mt-3 flex flex-wrap gap-1">
            <span class="rounded border border-base-300 px-1.5 py-0.5 text-[0.7rem] text-base-content/70">
              {template.pattern_id}
            </span>
            <span class="rounded border border-base-300 px-1.5 py-0.5 text-[0.7rem] text-base-content/70">
              {template.authority}
            </span>
            <span
              :for={parameter <- template.parameters}
              class="rounded border border-base-300 px-1.5 py-0.5 text-[0.7rem] text-base-content/70"
            >
              {parameter.name}{required_suffix(parameter)}
            </span>
          </div>

          <ol :if={template.files != []} class="mt-3 space-y-1 text-xs">
            <li
              :for={file <- template.files}
              class="flex items-center justify-between gap-3 rounded bg-base-100/70 px-2 py-1"
            >
              <span class="workspace-mono min-w-0 truncate">{file.path}</span>
              <span class="shrink-0 text-base-content/50">{short_hash(file.sha256)}</span>
            </li>
          </ol>
        </article>

        <p :if={@marketplace_templates == []} class="text-sm text-base-content/70">
          No marketplace templates installed.
        </p>
      </section>

      <form
        id="workspace-create-params"
        class="space-y-4"
        phx-change="change_template_params"
        phx-target={@myself}
      >
        <div class="grid gap-3 md:grid-cols-2">
          <label :for={field <- parameter_fields(@selected_pattern)} class="form-control">
            <span class="label">
              <span class="label-text">{field.label}</span>
            </span>
            <select
              :if={field.type == :enum}
              id={"workspace-create-param-#{field.name}"}
              name={"template[#{field.name}]"}
              class="select select-bordered select-sm w-full"
              disabled={!@enabled?}
            >
              <option
                :for={value <- field.allowed_values}
                value={value}
                selected={Map.get(@template_params, field.name) == value}
              >
                {value}
              </option>
            </select>
            <input
              :if={field.type != :enum}
              id={"workspace-create-param-#{field.name}"}
              name={"template[#{field.name}]"}
              type="text"
              value={Map.get(@template_params, field.name, "")}
              maxlength={field.max_length}
              class="input input-bordered input-sm w-full"
              phx-debounce="300"
              disabled={!@enabled?}
            />
          </label>
        </div>
      </form>

      <section class="rounded border border-base-300 p-3" aria-label="Output mode">
        <div class="flex flex-wrap gap-2" data-output-mode={@output_mode}>
          <button
            id="workspace-create-mode-scaffold"
            type="button"
            class={[
              "btn btn-sm",
              @output_mode == "developer_scaffold" && "btn-primary",
              @output_mode != "developer_scaffold" && "btn-outline"
            ]}
            phx-click="select_template_mode"
            phx-target={@myself}
            phx-value-mode="developer_scaffold"
            disabled={!@enabled?}
          >
            Developer scaffold
          </button>
          <button
            id="workspace-create-mode-live"
            type="button"
            class={[
              "btn btn-sm",
              @output_mode == "live_integration" && "btn-primary",
              @output_mode != "live_integration" && "btn-outline"
            ]}
            phx-click="select_template_mode"
            phx-target={@myself}
            phx-value-mode="live_integration"
            disabled={!@enabled? || !live_integration?(@selected_pattern)}
            aria-disabled={bool_attribute(!live_integration?(@selected_pattern))}
          >
            Live integration
          </button>
        </div>
      </section>

      <section id="workspace-create-preview" class="rounded border border-base-300 p-3">
        <header class="mb-3 flex items-center justify-between gap-3">
          <h3 class="text-sm font-medium">Preview</h3>
          <span class="text-xs text-base-content/60">
            {length(@preview.files)} files
          </span>
        </header>

        <p :if={@preview.message} class="text-sm text-base-content/70">
          {@preview.message}
        </p>

        <ol :if={@preview.files != []} class="space-y-1 text-sm">
          <li
            :for={file <- @preview.files}
            class="flex items-center justify-between gap-3 rounded bg-base-200/60 px-2 py-1"
          >
            <span class="workspace-mono min-w-0 truncate">{file.path}</span>
            <span class="shrink-0 text-xs text-base-content/60">{file.bytes} bytes</span>
          </li>
        </ol>
      </section>

      <section
        id="workspace-create-validate"
        class="rounded border border-base-300 p-3"
        data-validation-status={@preview.status}
      >
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h3 class="text-sm font-medium">Validation</h3>
            <p class="text-sm text-base-content/70">{@preview.validation}</p>
          </div>
          <button
            id="workspace-create-run"
            type="button"
            class="btn btn-primary btn-sm"
            phx-click="attempt_template_create"
            phx-target={@myself}
            disabled={!@enabled? || @preview.status != :ready}
          >
            Create
          </button>
        </div>

        <p
          :if={@create_attempt}
          id="workspace-create-attempt"
          class={["mt-3 rounded p-3 text-sm", attempt_class(@create_attempt.status)]}
          data-attempt-status={@create_attempt.status}
        >
          {@create_attempt.message}
        </p>
      </section>
    </section>
    """
  end

  defp create_enabled? do
    case Settings.get("templates.create.enabled") do
      {:ok, true} -> true
      _other -> false
    end
  end

  defp installed_marketplace_templates do
    case MarketplaceTemplates.list_installed() do
      {:ok, templates} -> templates
      {:error, _diagnostic} -> []
    end
  end

  defp visible_patterns do
    allowed = allowed_patterns()

    Templates.list_patterns()
    |> Enum.filter(&(&1.id in allowed))
  end

  defp allowed_patterns do
    case Settings.get("templates.allowed_patterns") do
      {:ok, values} when is_list(values) -> values
      _other -> @default_allowed_patterns
    end
  end

  defp selected_pattern_id(assigns, patterns) do
    existing = Map.get(assigns, :selected_pattern_id)
    allowed_ids = Enum.map(patterns, & &1.id)

    cond do
      existing in allowed_ids -> existing
      "llm_tool" in allowed_ids -> "llm_tool"
      allowed_ids != [] -> hd(allowed_ids)
      true -> nil
    end
  end

  defp pattern_by_id(patterns, pattern_id) do
    Enum.find(patterns, &(&1.id == pattern_id))
  end

  defp template_params(assigns, nil), do: Map.get(assigns, :template_params, %{})

  defp template_params(assigns, pattern) do
    current = Map.get(assigns, :template_params, %{})

    if Map.get(assigns, :selected_pattern_id) == pattern.id and current != %{} do
      current
    else
      default_params(pattern)
    end
  end

  defp default_params(pattern) do
    pattern
    |> Map.get(:parameters, [])
    |> Enum.reduce(%{}, fn entry, acc ->
      Map.put(acc, entry.name, default_value(pattern.id, entry))
    end)
  end

  defp default_value(pattern_id, %{name: "name"}), do: "new_#{pattern_id}"
  defp default_value(_pattern_id, %{default: value}), do: to_string(value)

  defp default_value(_pattern_id, %{type: :enum, allowed_values: [value | _values]}),
    do: value

  defp default_value(_pattern_id, _entry), do: ""

  defp output_mode(assigns, pattern) do
    assigns
    |> Map.get(:output_mode, "developer_scaffold")
    |> normalize_mode(pattern)
  end

  defp normalize_mode("live_integration", _pattern), do: "live_integration"
  defp normalize_mode(_mode, _pattern), do: "developer_scaffold"

  defp refresh_preview(socket) do
    assign(
      socket,
      :preview,
      preview(
        socket.assigns.selected_pattern_id,
        socket.assigns.template_params,
        socket.assigns.output_mode,
        socket.assigns.enabled?,
        action_context(socket.assigns)
      )
    )
  end

  defp preview(nil, _params, _mode, _enabled?, _context) do
    %{
      status: :denied,
      files: [],
      message: "No template pattern is selected.",
      validation: "No template pattern is selected."
    }
  end

  defp preview(_pattern_id, _params, _mode, false, _context) do
    %{
      status: :denied,
      files: [],
      message: "Preview is unavailable while template creation is disabled.",
      validation: "Denied by templates.create.enabled=false."
    }
  end

  defp preview(pattern_id, params, mode, true, context) do
    case Scaffold.preview(pattern_id, params) do
      {:ok, scaffold_preview} ->
        validate_preview(scaffold_preview, pattern_id, params, mode, context)

      {:error, reason} ->
        %{
          status: :denied,
          files: [],
          message: "Preview could not be rendered.",
          validation: bounded_reason(reason)
        }
    end
  end

  defp validate_preview(scaffold_preview, pattern_id, params, mode, context) do
    action_params = %{pattern_id: pattern_id, params: params, mode: mode}

    case Runner.run("validate_template", action_params, context) do
      {:ok, %{status: :completed} = response} ->
        %{
          status: :ready,
          files: scaffold_preview.files,
          message: target_message(scaffold_preview),
          validation: Map.get(response, :message) || validation_message(scaffold_preview)
        }

      {:ok, %{status: status} = response} ->
        %{
          status: status,
          files: scaffold_preview.files,
          message: target_message(scaffold_preview),
          validation:
            "#{Map.get(response, :message, "Template validation was denied.")} #{bounded_error(Map.get(response, :error))}"
            |> String.trim()
        }
    end
  end

  defp target_message(%{target_root: target_root, existing?: true}) do
    "Target exists: #{Path.relative_to_cwd(target_root)}"
  end

  defp target_message(%{target_root: target_root}) do
    "Target: #{Path.relative_to_cwd(target_root)}"
  end

  defp validation_message(%{live_integration?: live?, target_shapes: shapes}) do
    live_status = if live?, do: "live integration eligible", else: "developer scaffold only"
    "Rendered #{Enum.join(shapes, ", ")}; #{live_status}."
  end

  defp create_attempt(%{assigns: %{enabled?: false}}) do
    %{
      status: :denied,
      message: "Denied by templates.create.enabled=false."
    }
  end

  defp create_attempt(%{assigns: %{selected_pattern: nil, preview: %{status: status}}}) do
    %{
      status: :denied,
      message: "No template pattern is selected; status=#{inspect(status)}."
    }
  end

  defp create_attempt(%{assigns: %{preview: %{status: status}}}) when status != :ready do
    %{
      status: :denied,
      message: "Template preview is not ready."
    }
  end

  defp create_attempt(%{
         assigns: %{
           selected_pattern: %{live_integration?: false} = pattern,
           output_mode: "live_integration"
         }
       }) do
    %{
      status: :denied,
      message: "#{pattern.id} templates are developer-scaffold-only in v0.38."
    }
  end

  defp create_attempt(%{assigns: %{output_mode: "live_integration"}} = socket) do
    run_template_action("create_from_template", socket)
  end

  defp create_attempt(socket) do
    run_template_action("scaffold_template", socket)
  end

  defp run_template_action(action_name, socket) do
    params = %{
      pattern_id: socket.assigns.selected_pattern_id,
      params: socket.assigns.template_params,
      mode: socket.assigns.output_mode
    }

    case Runner.run(action_name, params, action_context(socket.assigns)) do
      {:ok, response} -> attempt_from_response(response)
    end
  end

  defp attempt_from_response(%{status: :completed, message: message} = response) do
    %{
      status: :completed,
      message: message,
      draft: Map.get(response, :draft),
      scaffold: Map.get(response, :scaffold),
      next_actions: Map.get(response, :next_actions, [])
    }
  end

  defp attempt_from_response(%{status: status, message: message} = response) do
    %{
      status: status,
      message: response_message(message, Map.get(response, :error)),
      error: Map.get(response, :error)
    }
  end

  defp response_message(message, nil), do: message

  defp response_message(message, reason) do
    error = bounded_error(reason)

    if String.contains?(message, error) do
      message
    else
      "#{message} #{error}" |> String.trim()
    end
  end

  defp action_context(assigns) do
    context = Map.get(assigns, :renderer_context, %{})

    %{
      actor: Map.get(context, :user_id) || "local",
      operator_id: Map.get(context, :user_id) || "local",
      user_id: Map.get(context, :user_id) || "local",
      thread_id: Map.get(context, :thread_id),
      channel: :live_view,
      surface: "/workspace",
      canvas_destination: Map.get(context, :canvas_destination)
    }
  end

  defp parameter_names(nil), do: []

  defp parameter_names(pattern) do
    pattern
    |> Map.get(:parameters, [])
    |> Enum.map(& &1.name)
  end

  defp parameter_fields(nil), do: []

  defp parameter_fields(pattern) do
    Enum.map(Map.get(pattern, :parameters, []), fn entry ->
      %{
        name: entry.name,
        type: entry.type,
        label: humanize(entry.name),
        allowed_values: Map.get(entry, :allowed_values, []),
        max_length: Map.get(entry, :max_length, 256)
      }
    end)
  end

  defp normalize_pattern_id(pattern_id) when is_binary(pattern_id) do
    pattern_id
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_pattern_id(pattern_id), do: to_string(pattern_id)

  defp live_integration?(%{live_integration?: true}), do: true
  defp live_integration?(_pattern), do: false

  defp status_class(:ready), do: "workspace-status-success"
  defp status_class(:denied), do: "workspace-status-danger"
  defp status_class(_status), do: "workspace-status-neutral"

  defp status_label(:ready), do: "ready"
  defp status_label(:denied), do: "denied"
  defp status_label(status), do: to_string(status)

  defp attempt_class(:denied), do: "border border-error/30 bg-error/10"
  defp attempt_class(:completed), do: "border border-success/30 bg-success/10"
  defp attempt_class(_status), do: "border border-base-300 bg-base-200/60"

  defp bounded_reason(reason) do
    reason
    |> inspect(limit: 6, printable_limit: 220)
    |> String.slice(0, 320)
  end

  defp bounded_error(nil), do: ""
  defp bounded_error(reason), do: bounded_reason(reason)

  defp humanize(name) do
    name
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp dom_id(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_-]/, "-")
  end

  defp required_suffix(%{required?: true}), do: " *"
  defp required_suffix(_parameter), do: ""

  defp short_hash(sha256) when is_binary(sha256), do: String.slice(sha256, 0, 12)
  defp short_hash(_sha256), do: ""

  defp bool_attribute(true), do: "true"
  defp bool_attribute(false), do: "false"
end
