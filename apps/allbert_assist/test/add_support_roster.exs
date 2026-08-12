defmodule AddSupportRoster do
  def run() do
    fixture_path = "/Users/spuri/projects/lexlapax/allbert-assist/apps/allbert_assist/test/fixtures/v1.4/m1a3_effect_boundaries.json"

    fixture = fixture_path
    |> File.read!()
    |> Jason.decode!()

    # Add support.ex as a roster row
    support_row = %{
      "admission_mode" => "ready_carried",
      "carrier_policy" => "carries channel CLI E1 for update operations",
      "compatibility_provenance" => nil,
      "entrypoint" => "channel update helpers",
      "focused_test" => "AllbertAssist.CLI.Areas.ChannelsTest",
      "id" => "channel-cli-support",
      "missing_or_stale_result" => "{:error, :product_not_ready} before channel update effect",
      "owner" => "AllbertAssist.CLI.Channels.Support",
      "phase" => "ready",
      "source_path" => "apps/allbert_assist/lib/allbert_assist/cli/channels/support.ex"
    }

    # Add row
    updated_rows = fixture["rows"] ++ [support_row]
    |> Enum.sort_by(fn r -> r["id"] end)

    # Update support.ex classification to point to new roster_id
    updated_classifications = fixture["candidate_classifications"]
    |> Enum.map(fn c ->
      case {c["source_path"], c["line"]} do
        {"apps/allbert_assist/lib/allbert_assist/cli/channels/support.ex", 192} ->
          Map.put(c, "roster_id", "channel-cli-support")
        _other -> c
      end
    end)

    updated = fixture
    |> Map.put("rows", updated_rows)
    |> Map.put("candidate_classifications", updated_classifications)

    json = Jason.encode!(updated, pretty: true)
    File.write!(fixture_path, json)

    IO.puts("Added support.ex roster row")
  end
end

AddSupportRoster.run()
