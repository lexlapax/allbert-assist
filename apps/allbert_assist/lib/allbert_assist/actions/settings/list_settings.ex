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
      render_mode: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    render_mode = render_mode(params, context)

    with {:ok, settings} <- Settings.list(namespace: Map.get(params, :namespace)) do
      {:ok,
       %{
         message: message(settings, render_mode),
         status: PermissionGate.response_status(permission_decision),
         settings: settings,
         actions: [action(settings, permission_decision, render_mode)]
       }}
    end
  end

  defp message(settings, :operator_report) do
    rendered =
      settings
      |> Enum.map(&"- #{&1.key}: #{inspect(&1.value)} (#{&1.source})")
      |> Enum.join("\n")

    "Settings Central values:\n\n#{rendered}"
  end

  defp message(settings, :assistant_summary) do
    count = length(settings)

    "Settings Central has #{count} values loaded. I can discuss settings safely here, " <>
      "but I won't dump the full operator report in chat. Use `/settings get <key>` " <>
      "for exact TUI reads or `mix allbert.settings list` for the full operator report."
  end

  defp action(settings, permission_decision, render_mode) do
    %{
      name: "list_settings",
      status: :completed,
      permission: :read_only,
      permission_decision: permission_decision,
      settings_metadata: %{count: length(settings), render_mode: render_mode}
    }
  end

  defp render_mode(params, context) do
    case field(params, :render_mode) || field(params, :mode) || field(context, :render_mode) do
      value when value in [:operator_report, "operator_report", :raw, "raw"] -> :operator_report
      _other -> :assistant_summary
    end
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_map, _key), do: nil
end
