defmodule AllbertAssist.Actions.Settings.SetNotesRoot do
  @moduledoc """
  Set the local notes/files root (`apps.notes_files.notes_root`) as a dedicated,
  config-free operator affordance (v0.65 M2).

  This is the product path a non-developer uses to "connect a notes folder" — from
  onboarding, the web/settings affordance, or `allbert admin notes set-root PATH` —
  instead of hand-editing config or reaching for the generic
  `admin settings set apps.notes_files.notes_root`. It validates that the path is an
  existing directory, then writes the single safe Settings Central key through the same
  `Settings.put/3` seam as `update_setting`. No new authority: it carries the existing
  `:settings_write` class and confirmation floor.
  """

  use AllbertAssist.Action,
    permission: :settings_write,
    exposure: :internal,
    execution_mode: :settings_write,
    skill_backed?: false,
    confirmation: :not_required,
    name: "set_notes_root",
    description: "Set the local notes/files root directory (config-free connect affordance).",
    category: "settings",
    tags: ["settings", "write", "notes", "local_knowledge"],
    schema: [
      path: [
        type: :string,
        required: true,
        doc: "An existing local directory to use as the notes root."
      ]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings

  @key "apps.notes_files.notes_root"

  @impl true
  def run(%{path: path}, context) do
    permission_decision = PermissionGate.authorize(:settings_write, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, root} <- validate_root(path),
         {:ok, setting} <-
           Settings.put(@key, root, action_context(context, permission_decision)) do
      {:ok,
       %{
         message: "Notes root set to #{setting.value}.",
         status: :completed,
         setting: setting,
         actions: [action(setting, permission_decision)]
       }}
    else
      false -> denied(path, permission_decision, :permission_denied)
      {:error, reason} -> denied(path, permission_decision, reason)
    end
  end

  # Config-free connect must fail closed on a path that is not an existing directory,
  # so the operator gets a clear error instead of a silently-broken notes root.
  defp validate_root(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" -> {:error, :empty_path}
      true -> validate_directory(Path.expand(trimmed))
    end
  end

  defp validate_root(_path), do: {:error, :invalid_path}

  defp validate_directory(root) do
    cond do
      not File.exists?(root) -> {:error, {:not_found, root}}
      not File.dir?(root) -> {:error, {:not_a_directory, root}}
      true -> {:ok, root}
    end
  end

  defp denied(path, permission_decision, reason) do
    {:ok,
     %{
       message: "I could not set the notes root to #{inspect(path)}: #{inspect(reason)}",
       status: :denied,
       actions: [
         %{
           name: "set_notes_root",
           status: :denied,
           permission: :settings_write,
           permission_decision: permission_decision,
           settings_metadata: %{setting_key: @key, value: path, error: reason}
         }
       ]
     }}
  end

  defp action(setting, permission_decision) do
    %{
      name: "set_notes_root",
      status: :completed,
      permission: :settings_write,
      permission_decision: permission_decision,
      settings_metadata: %{
        setting_key: setting.key,
        source_layer: setting.source,
        audit_path: audit_path(setting.diagnostics)
      }
    }
  end

  defp action_context(context, permission_decision) do
    request_context = Map.get(context, :request, context)

    request_context
    |> Map.take([:actor, :operator_id, :channel, :input_signal_id])
    |> Map.new(fn
      {:operator_id, value} -> {:actor, value}
      {:input_signal_id, value} -> {:source_signal_id, value}
      other -> other
    end)
    |> Map.put(:permission_decision, permission_decision)
  end

  defp audit_path(diagnostics) do
    diagnostics
    |> Enum.find_value(&Map.get(&1, :audit_path))
  end
end
