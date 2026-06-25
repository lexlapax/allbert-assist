defmodule AllbertAssist.Actions.Settings.ListSettings do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :settings_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "list_settings",
    description: "List Settings Central values with source metadata.",
    category: "settings",
    tags: ["settings", "read_only"],
    schema: [
      namespace: [type: :string, required: false],
      render_mode: [type: :string, required: false],
      surface: [type: :string, required: false],
      surface_policy_affordance: [type: :boolean, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings
  alias AllbertAssist.SurfacePolicy

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    policy = SurfacePolicy.report_policy(name(), params, context)

    with {:ok, settings} <- Settings.list(namespace: Map.get(params, :namespace)) do
      visible_settings = bounded(settings, policy)

      {:ok,
       %{
         message: message(visible_settings, length(settings), policy),
         status: PermissionGate.response_status(permission_decision),
         settings: visible_settings,
         actions: [action(settings, visible_settings, permission_decision, policy)]
       }}
    end
  end

  defp message(settings, total_count, %{render_mode: :operator_report}) do
    rendered =
      settings
      |> Enum.map(&"- #{&1.key}: #{inspect(&1.value)} (#{&1.source})")
      |> Enum.join("\n")

    suffix =
      if length(settings) < total_count do
        "\n\nShowing #{length(settings)} of #{total_count} rows under surface policy."
      else
        ""
      end

    "Settings Central values:\n\n#{rendered}#{suffix}"
  end

  defp message(_settings, total_count, %{render_mode: :assistant_summary}) do
    "Settings Central has #{total_count} values loaded. I can discuss settings safely here, " <>
      "but I won't dump the full operator report in chat. Use `/settings get <key>` " <>
      "for exact TUI reads or `mix allbert.settings list` for the full operator report."
  end

  defp action(settings, visible_settings, permission_decision, policy) do
    %{
      name: "list_settings",
      status: :completed,
      permission: :read_only,
      permission_decision: permission_decision,
      settings_metadata: %{
        count: length(settings),
        rendered_count: length(visible_settings),
        render_mode: policy.render_mode,
        max_rows: policy.max_rows,
        surface_policy_source: policy.source
      }
    }
  end

  defp bounded(rows, policy), do: Enum.take(rows, policy.max_rows)
end
