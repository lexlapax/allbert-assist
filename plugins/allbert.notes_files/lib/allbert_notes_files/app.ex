defmodule AllbertNotesFiles.App do
  @moduledoc """
  Notes/files app contract and workspace surface provider.
  """

  use AllbertAssist.App
  use AllbertAssist.App.SurfaceProvider

  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertNotesFiles.{Notes, SettingsFragment}

  @list_panel_id :notes_files_list_panel
  @detail_panel_id :notes_files_detail_panel

  @impl true
  def app_id, do: :notes_files

  @impl true
  def display_name, do: "Notes/files"

  @impl true
  def version, do: "0.42.0"

  @impl true
  def validate(_opts), do: :ok

  @impl AllbertAssist.App
  def actions, do: AllbertNotesFiles.Plugin.actions()

  @impl AllbertAssist.App
  def skill_paths, do: AllbertNotesFiles.Plugin.skill_paths()

  @impl AllbertAssist.App
  def settings_schema, do: SettingsFragment.entries()

  @impl AllbertAssist.App
  def memory_namespace do
    %{
      app_id: :notes_files,
      namespace: :notes_files,
      writable: false,
      description:
        "Read-only declaration for notes/files references; note files never auto-promote into memory."
    }
  end

  @impl AllbertAssist.App
  def surfaces do
    [
      list_panel([empty_state("notes-empty", "No notes found", "The configured notes root is empty.")]),
      detail_panel([empty_state("note-detail-empty", "No note selected", "Select or read a note.")])
    ]
  end

  def workspace_panel_surfaces(_context) do
    max_results = Notes.max_results()

    {:ok, notes} = Notes.search("", limit: max_results)
    [list_panel(note_rows(notes)), detail_panel(detail_nodes(List.first(notes)))]
  end

  def surface_catalog, do: []

  def intent_descriptors do
    [
      %{
        app_id: :notes_files,
        action_name: "search_notes",
        label: "Search local notes",
        examples: [
          "find notes about onboarding",
          "search notes for release checklist"
        ],
        synonyms: ["notes", "local notes", "find notes", "search notes"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :notes_files,
        action_name: "read_note",
        label: "Read a local note",
        examples: [
          "read the onboarding note",
          "open the scratch note"
        ],
        synonyms: ["read note", "open note", "show note"],
        required_slots: [],
        handoff_required?: true
      }
    ]
  end

  defp list_panel(children),
    do: panel(@list_panel_id, "Notes/files", 200, children)

  defp detail_panel(children),
    do: panel(@detail_panel_id, "Note detail", 210, children)

  defp panel(id, label, order, children) do
    %Surface{
      id: id,
      app_id: :notes_files,
      label: label,
      path: "/workspace",
      kind: :panel,
      zone: :canvas_panels,
      status: :available,
      nodes: [
        %Node{
          id: panel_root_id(id),
          component: :panel,
          props: %{title: label, body: "Local note references.", status: "ready"},
          children: children
        }
      ],
      fallback_text: "#{label} is available from the Notes/files workspace panels.",
      metadata: %{zone: :canvas_panels, visible_when: :selected_app, order: order}
    }
  end

  defp note_rows([]), do: [empty_state("notes-empty", "No notes found", "The configured notes root is empty.")]

  defp note_rows(notes) do
    Enum.map(notes, fn note ->
      %Node{
        id: "note-row-#{safe_id(note.relative_path)}",
        component: :row,
        props: %{
          title: note.title,
          body: "#{note.relative_path} - #{note.excerpt}",
          external_id: note.relative_path
        }
      }
    end)
  end

  defp detail_nodes(nil) do
    [empty_state("note-detail-empty", "No note selected", "Search or read a note to inspect details.")]
  end

  defp detail_nodes(note) do
    [
      %Node{
        id: "note-detail-#{safe_id(note.relative_path)}",
        component: :text,
        props: %{
          title: note.title,
          body: note.excerpt,
          external_id: note.relative_path,
          status: "read_only"
        }
      }
    ]
  end

  defp empty_state(id, title, body) do
    %Node{id: id, component: :empty_state, props: %{title: title, body: body}}
  end

  defp panel_root_id(id), do: id |> Atom.to_string() |> String.replace("_", "-")

  defp safe_id(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "note"
      id -> String.slice(id, 0, 48)
    end
  end
end
