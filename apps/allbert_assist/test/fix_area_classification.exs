defmodule FixAreaClassification do
  def run() do
    fixture_path = "/Users/spuri/projects/lexlapax/allbert-assist/apps/allbert_assist/test/fixtures/v1.4/m1a3_effect_boundaries.json"

    fixture = fixture_path
    |> File.read!()
    |> Jason.decode!()

    # Fix the area.ex classification by removing it and re-adding it with roster_id
    updated_classifications = fixture["candidate_classifications"]
    |> Enum.reject(fn c ->
      c["source_path"] == "apps/allbert_assist/lib/allbert_assist/cli/area.ex" and
      c["line"] == 20
    end)
    |> Kernel.++(
      [%{
        "boundary" => "AllbertAssist.CLI.Area",
        "disposition" => "inherited_context",
        "evidence" => "Behavior contract that documents dispatch/2 receives :allbert_pack_epoch.",
        "line" => 20,
        "roster_id" => "",
        "source_path" => "apps/allbert_assist/lib/allbert_assist/cli/area.ex"
      }]
    )
    |> Enum.sort_by(fn c -> {c["source_path"], c["line"]} end)

    updated = fixture
    |> Map.put("candidate_classifications", updated_classifications)

    json = Jason.encode!(updated, pretty: true)
    File.write!(fixture_path, json)

    IO.puts("Fixed area.ex classification")
  end
end

FixAreaClassification.run()
