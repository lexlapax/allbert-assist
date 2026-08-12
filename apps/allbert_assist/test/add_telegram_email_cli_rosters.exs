defmodule AddTelegramEmailCliRosters do
  def run() do
    fixture_path = "/Users/spuri/projects/lexlapax/allbert-assist/apps/allbert_assist/test/fixtures/v1.4/m1a3_effect_boundaries.json"

    fixture = fixture_path
    |> File.read!()
    |> Jason.decode!()

    # Add telegram and email CLI as roster rows
    telegram_row = %{
      "admission_mode" => "ready_carried",
      "carrier_policy" => "carries telegram CLI E1 for simulation",
      "compatibility_provenance" => nil,
      "entrypoint" => "telegram simulation routes",
      "focused_test" => "AllbertTelegram.CLITest",
      "id" => "telegram-cli",
      "missing_or_stale_result" => "{:error, :product_not_ready} before telegram simulation effect",
      "owner" => "AllbertTelegram.CLI",
      "phase" => "ready",
      "source_path" => "apps/allbert_telegram/lib/allbert_telegram/cli.ex"
    }

    email_row = %{
      "admission_mode" => "ready_carried",
      "carrier_policy" => "carries email CLI E1 for simulation",
      "compatibility_provenance" => nil,
      "entrypoint" => "email simulation routes",
      "focused_test" => "AllbertEmail.CLITest",
      "id" => "email-cli",
      "missing_or_stale_result" => "{:error, :product_not_ready} before email simulation effect",
      "owner" => "AllbertEmail.CLI",
      "phase" => "ready",
      "source_path" => "apps/allbert_email/lib/allbert_email/cli.ex"
    }

    notes_row = %{
      "admission_mode" => "ready_carried",
      "carrier_policy" => "carries notes CLI E1 for simulation",
      "compatibility_provenance" => nil,
      "entrypoint" => "notes simulation routes",
      "focused_test" => "AllbertNotesFiles.CLITest",
      "id" => "notes-cli",
      "missing_or_stale_result" => "{:error, :product_not_ready} before notes simulation effect",
      "owner" => "AllbertNotesFiles.CLI",
      "phase" => "ready",
      "source_path" => "apps/allbert_notes_files/lib/allbert_notes_files/cli.ex"
    }

    # Add rows
    updated_rows = fixture["rows"] ++ [telegram_row, email_row, notes_row]
    |> Enum.sort_by(fn r -> r["id"] end)

    # Update classifications to point to new roster_ids
    updated_classifications = fixture["candidate_classifications"]
    |> Enum.map(fn c ->
      case c["source_path"] do
        "apps/allbert_telegram/lib/allbert_telegram/cli.ex" ->
          Map.put(c, "roster_id", "telegram-cli")
        "apps/allbert_email/lib/allbert_email/cli.ex" ->
          Map.put(c, "roster_id", "email-cli")
        "apps/allbert_notes_files/lib/allbert_notes_files/cli.ex" ->
          Map.put(c, "roster_id", "notes-cli")
        _other -> c
      end
    end)

    updated = fixture
    |> Map.put("rows", updated_rows)
    |> Map.put("candidate_classifications", updated_classifications)

    json = Jason.encode!(updated, pretty: true)
    File.write!(fixture_path, json)

    IO.puts("Added telegram/email/notes CLI roster rows")
  end
end

AddTelegramEmailCliRosters.run()
