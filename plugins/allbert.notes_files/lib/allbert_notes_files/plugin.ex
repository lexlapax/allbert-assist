defmodule AllbertNotesFiles.Plugin do
  @moduledoc """
  Shipped v0.42 reference plugin for local notes/files workflows.

  The plugin contributes contract metadata only. Discovery and registration do
  not grant filesystem authority, memory promotion rights, or confirmation
  bypasses.
  """

  use AllbertAssist.Plugin

  @impl true
  def plugin_id, do: "allbert.notes_files"

  @impl true
  def display_name, do: "Allbert Notes/Files"

  @impl true
  def version, do: "0.42.0"

  @impl true
  def validate(_opts), do: :ok

  @impl true
  def apps, do: [AllbertNotesFiles.App]

  @impl true
  def actions do
    [
      AllbertNotesFiles.Actions.SearchNotes,
      AllbertNotesFiles.Actions.ReadNote,
      AllbertNotesFiles.Actions.WriteNote
    ]
  end

  @impl true
  def skill_paths do
    [Path.expand("../../skills", __DIR__)]
  end

  @impl true
  def settings_schema, do: []
end
