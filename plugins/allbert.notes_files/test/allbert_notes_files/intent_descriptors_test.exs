defmodule AllbertNotesFiles.IntentDescriptorsTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Intent.Descriptor

  test "notes descriptors declare and extract their package-owned slots" do
    descriptors =
      AllbertNotesFiles.App.intent_descriptors()
      |> Descriptor.normalize_many(app_id: :notes_files)
      |> Map.fetch!(:descriptors)
      |> Map.new(&{&1.action_name, &1})

    write_note = Map.fetch!(descriptors, "write_note")
    assert write_note.required_slots == [:title, :body]

    assert %{
             extracted_slots: %{title: "release check", body: "slot coverage"},
             missing_slots: []
           } =
             Descriptor.extract_slots(
               write_note,
               "create a note titled release check with body slot coverage"
             )

    read_note = Map.fetch!(descriptors, "read_note")
    assert read_note.required_slots == [:path]

    assert %{extracted_slots: %{path: "scratch.md"}, missing_slots: []} =
             Descriptor.extract_slots(read_note, "read the scratch note")
  end
end
