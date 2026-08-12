defmodule FinalFixtureFix do
  def run() do
    fixture_path = "/Users/spuri/projects/lexlapax/allbert-assist/apps/allbert_assist/test/fixtures/v1.4/m1a3_effect_boundaries.json"

    fixture = fixture_path
    |> File.read!()
    |> Jason.decode!()

    # Path remapping for rows
    updated_rows = fixture["rows"]
    |> Enum.map(fn row ->
      case row["source_path"] do
        "apps/allbert_assist/lib/allbert_assist/cli/areas/notes.ex" ->
          Map.put(row, "source_path", "apps/allbert_notes_files/lib/allbert_notes_files/cli.ex")
        other -> row
      end
    end)

    # Remove duplicates in classifications while keeping only the first occurrence
    updated_classifications = fixture["candidate_classifications"]
    |> Enum.uniq_by(fn c -> {c["source_path"], c["line"], c["boundary"]} end)
    |> Enum.sort_by(fn c -> {c["source_path"], c["line"]} end)

    updated = fixture
    |> Map.put("rows", updated_rows)
    |> Map.put("candidate_classifications", updated_classifications)

    json = Jason.encode!(updated, pretty: true)
    File.write!(fixture_path, json)

    IO.puts("Fixture fixed successfully")
    IO.puts("Removed duplicates in classifications")
    IO.puts("Updated notes.ex row source_path")
  end
end

FinalFixtureFix.run()
