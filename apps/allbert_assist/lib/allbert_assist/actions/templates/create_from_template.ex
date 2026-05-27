defmodule AllbertAssist.Actions.Templates.CreateFromTemplate do
  @moduledoc """
  Registered action for creating a v0.37 dynamic draft from a reviewed template.
  """

  use AllbertAssist.Action,
    permission: :dynamic_codegen_request,
    exposure: :internal,
    execution_mode: :template_dynamic_draft,
    skill_backed?: false,
    confirmation: :not_required,
    name: "create_from_template",
    description: "Create a dynamic draft from a reviewed live-integration template.",
    category: "templates",
    tags: ["templates", "dynamic-plugins", "template_pattern"],
    schema: [
      pattern_id: [type: :string, required: true],
      params: [type: :map, required: true],
      mode: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      draft: [type: :map, required: false],
      manifest: [type: :map, required: false],
      next_actions: [type: {:list, :map}, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings
  alias AllbertAssist.Templates.LiveDraft

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(:dynamic_codegen_request, context)

    with :ok <- ensure_mode(params),
         :ok <- ensure_template_create_enabled(),
         :ok <- ensure_dynamic_codegen_enabled(),
         :ok <- ensure_dynamic_live_loader_enabled(),
         :ok <- ensure_sandbox_elixir_enabled(),
         true <- PermissionGate.allowed?(permission_decision),
         {:ok, result} <-
           LiveDraft.create(pattern_id(params), template_params(params), live_draft_opts(context)) do
      {:ok,
       %{
         message:
           "Templated dynamic draft #{result.draft.slug} created. Run trial, gate, then integration approval next.",
         status: :completed,
         permission_decision: permission_decision,
         draft: result.draft,
         manifest: result.manifest,
         next_actions: result.next_actions,
         diagnostics: result.diagnostics,
         actions: [action(:completed, permission_decision, result)]
       }}
    else
      false -> {:ok, denied(permission_decision, :permission_denied)}
      {:error, reason} -> {:ok, denied(permission_decision, reason)}
    end
  end

  def run(_params, context) do
    {:ok, denied(PermissionGate.authorize(:dynamic_codegen_request, context), :invalid_params)}
  end

  defp ensure_mode(params) do
    case Map.get(params, :mode) || Map.get(params, "mode") || "live_integration" do
      "live_integration" -> :ok
      mode -> {:error, {:unsupported_template_create_mode, mode}}
    end
  end

  defp ensure_template_create_enabled do
    case Settings.get("templates.create.enabled") do
      {:ok, true} -> :ok
      _other -> {:error, :template_create_disabled}
    end
  end

  defp ensure_dynamic_codegen_enabled do
    case Settings.get("dynamic_codegen.enabled") do
      {:ok, true} -> :ok
      _other -> {:error, :dynamic_codegen_disabled}
    end
  end

  defp ensure_dynamic_live_loader_enabled do
    case Settings.get("dynamic_codegen.live_loader_enabled") do
      {:ok, true} -> :ok
      _other -> {:error, :dynamic_live_loader_disabled}
    end
  end

  defp ensure_sandbox_elixir_enabled do
    case Settings.get("sandbox.elixir.enabled") do
      {:ok, true} -> :ok
      _other -> {:error, :sandbox_elixir_disabled}
    end
  end

  defp live_draft_opts(context) do
    [
      operator_id: operator_id(context),
      channel: Map.get(context, :channel) || Map.get(context, "channel"),
      surface: Map.get(context, :surface) || Map.get(context, "surface")
    ]
  end

  defp operator_id(context) do
    Map.get(context, :operator_id) || Map.get(context, "operator_id") ||
      Map.get(context, :user_id) || Map.get(context, "user_id") ||
      Map.get(context, :actor) || Map.get(context, "actor")
  end

  defp pattern_id(params), do: Map.get(params, :pattern_id) || Map.get(params, "pattern_id")
  defp template_params(params), do: Map.get(params, :params) || Map.get(params, "params") || %{}

  defp denied(permission_decision, reason) do
    %{
      message: "Template live draft was denied or unavailable: #{inspect(reason)}",
      status: :denied,
      error: reason,
      permission_decision: permission_decision,
      actions: [action(:denied, permission_decision, %{error: reason})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "create_from_template",
      status: status,
      permission: :dynamic_codegen_request,
      permission_decision: permission_decision,
      template_metadata: metadata
    }
  end
end
