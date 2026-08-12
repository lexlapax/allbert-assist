defmodule RemapFixture do
  def run() do
    fixture_path = "/Users/spuri/projects/lexlapax/allbert-assist/apps/allbert_assist/test/fixtures/v1.4/m1a3_effect_boundaries.json"

    fixture = fixture_path
    |> File.read!()
    |> Jason.decode!()

    # Path remapping for moved files
    remappings = %{
      "plugins/allbert.email/lib/allbert_assist/channels/email/adapter.ex" => "apps/allbert_email/lib/allbert_email/adapter.ex",
      "plugins/allbert.telegram/lib/allbert_assist/channels/telegram/adapter.ex" => "apps/allbert_telegram/lib/allbert_telegram/adapter.ex",
      "plugins/allbert.telegram/lib/allbert_assist/channels/telegram/client.ex" => "apps/allbert_telegram/lib/allbert_telegram/client.ex",
    }

    # Remap rows
    updated_rows = fixture["rows"]
    |> Enum.map(fn row ->
      case Map.get(remappings, row["source_path"]) do
        nil -> row
        new_path -> Map.put(row, "source_path", new_path)
      end
    end)

    # Remap classifications
    updated_classifications = fixture["candidate_classifications"]
    |> Enum.map(fn classification ->
      case Map.get(remappings, classification["source_path"]) do
        nil -> classification
        new_path -> Map.put(classification, "source_path", new_path)
      end
    end)
    |> add_missing_classifications()
    |> Enum.sort_by(fn c -> {c["source_path"], c["line"]} end)

    updated = fixture
    |> Map.put("rows", updated_rows)
    |> Map.put("candidate_classifications", updated_classifications)

    json = Jason.encode!(updated, pretty: true)
    File.write!(fixture_path, json)

    IO.puts("Fixture remapped successfully")
    IO.puts("Updated #{Enum.count(updated_classifications)} classifications")
  end

  defp add_missing_classifications(classifications) do
    # Add missing classifications for moved callsites
    new_classifications = [
      # apps/allbert_telegram/lib/allbert_telegram/adapter.ex
      %{
        "boundary" => "AllbertAssist.Actions.Runner.run",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 671,
        "roster_id" => "telegram-adapter",
        "source_path" => "apps/allbert_telegram/lib/allbert_telegram/adapter.ex"
      },
      %{
        "boundary" => "AllbertAssist.Actions.Runner.run",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 873,
        "roster_id" => "telegram-adapter",
        "source_path" => "apps/allbert_telegram/lib/allbert_telegram/adapter.ex"
      },
      %{
        "boundary" => "AllbertAssist.Channels.create_event",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 218,
        "roster_id" => "telegram-adapter",
        "source_path" => "apps/allbert_telegram/lib/allbert_telegram/adapter.ex"
      },
      %{
        "boundary" => "AllbertAssist.Channels.create_event",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 232,
        "roster_id" => "telegram-adapter",
        "source_path" => "apps/allbert_telegram/lib/allbert_telegram/adapter.ex"
      },
      %{
        "boundary" => "AllbertAssist.Channels.update_event",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 783,
        "roster_id" => "telegram-adapter",
        "source_path" => "apps/allbert_telegram/lib/allbert_telegram/adapter.ex"
      },
      %{
        "boundary" => "AllbertAssist.Channels.update_event",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 798,
        "roster_id" => "telegram-adapter",
        "source_path" => "apps/allbert_telegram/lib/allbert_telegram/adapter.ex"
      },
      %{
        "boundary" => "AllbertAssist.Channels.update_event",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 802,
        "roster_id" => "telegram-adapter",
        "source_path" => "apps/allbert_telegram/lib/allbert_telegram/adapter.ex"
      },
      %{
        "boundary" => "AllbertAssist.Channels.update_event",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 806,
        "roster_id" => "telegram-adapter",
        "source_path" => "apps/allbert_telegram/lib/allbert_telegram/adapter.ex"
      },
      %{
        "boundary" => "AllbertAssist.Channels.update_event",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 930,
        "roster_id" => "telegram-adapter",
        "source_path" => "apps/allbert_telegram/lib/allbert_telegram/adapter.ex"
      },
      %{
        "boundary" => "AllbertAssist.Runtime.acknowledge_deliveries",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 263,
        "roster_id" => "telegram-adapter",
        "source_path" => "apps/allbert_telegram/lib/allbert_telegram/adapter.ex"
      },
      %{
        "boundary" => "AllbertAssist.Runtime.acknowledge_deliveries",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 316,
        "roster_id" => "telegram-adapter",
        "source_path" => "apps/allbert_telegram/lib/allbert_telegram/adapter.ex"
      },
      %{
        "boundary" => "AllbertAssist.Runtime.submit_user_input",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 533,
        "roster_id" => "telegram-adapter",
        "source_path" => "apps/allbert_telegram/lib/allbert_telegram/adapter.ex"
      },
      # apps/allbert_email/lib/allbert_email/adapter.ex
      %{
        "boundary" => "AllbertAssist.Actions.Runner.run",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 417,
        "roster_id" => "email-adapter",
        "source_path" => "apps/allbert_email/lib/allbert_email/adapter.ex"
      },
      %{
        "boundary" => "AllbertAssist.Channels.create_event",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 248,
        "roster_id" => "email-adapter",
        "source_path" => "apps/allbert_email/lib/allbert_email/adapter.ex"
      },
      %{
        "boundary" => "AllbertAssist.Channels.update_event",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 566,
        "roster_id" => "email-adapter",
        "source_path" => "apps/allbert_email/lib/allbert_email/adapter.ex"
      },
      %{
        "boundary" => "AllbertAssist.Channels.update_event",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 581,
        "roster_id" => "email-adapter",
        "source_path" => "apps/allbert_email/lib/allbert_email/adapter.ex"
      },
      %{
        "boundary" => "AllbertAssist.Channels.update_event",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 585,
        "roster_id" => "email-adapter",
        "source_path" => "apps/allbert_email/lib/allbert_email/adapter.ex"
      },
      %{
        "boundary" => "AllbertAssist.Channels.update_event",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 589,
        "roster_id" => "email-adapter",
        "source_path" => "apps/allbert_email/lib/allbert_email/adapter.ex"
      },
      %{
        "boundary" => "AllbertAssist.Channels.update_event",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 595,
        "roster_id" => "email-adapter",
        "source_path" => "apps/allbert_email/lib/allbert_email/adapter.ex"
      },
      %{
        "boundary" => "AllbertAssist.Runtime.acknowledge_deliveries",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 220,
        "roster_id" => "email-adapter",
        "source_path" => "apps/allbert_email/lib/allbert_email/adapter.ex"
      },
      %{
        "boundary" => "AllbertAssist.Runtime.submit_user_input",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 486,
        "roster_id" => "email-adapter",
        "source_path" => "apps/allbert_email/lib/allbert_email/adapter.ex"
      },
      # apps/allbert_telegram/lib/allbert_telegram/cli.ex
      %{
        "boundary" => "AllbertAssist.Channels.create_event",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 131,
        "roster_id" => "channel-cli-simulation",
        "source_path" => "apps/allbert_telegram/lib/allbert_telegram/cli.ex"
      },
      %{
        "boundary" => "AllbertAssist.Runtime.acknowledge_deliveries",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 163,
        "roster_id" => "channel-cli-simulation",
        "source_path" => "apps/allbert_telegram/lib/allbert_telegram/cli.ex"
      },
      %{
        "boundary" => "AllbertAssist.Runtime.submit_user_input",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 145,
        "roster_id" => "channel-cli-simulation",
        "source_path" => "apps/allbert_telegram/lib/allbert_telegram/cli.ex"
      },
      # apps/allbert_email/lib/allbert_email/cli.ex
      %{
        "boundary" => "AllbertAssist.Channels.create_event",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 149,
        "roster_id" => "channel-cli-simulation",
        "source_path" => "apps/allbert_email/lib/allbert_email/cli.ex"
      },
      %{
        "boundary" => "AllbertAssist.Runtime.acknowledge_deliveries",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 180,
        "roster_id" => "channel-cli-simulation",
        "source_path" => "apps/allbert_email/lib/allbert_email/cli.ex"
      },
      %{
        "boundary" => "AllbertAssist.Runtime.submit_user_input",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 162,
        "roster_id" => "channel-cli-simulation",
        "source_path" => "apps/allbert_email/lib/allbert_email/cli.ex"
      },
      # apps/allbert_assist/lib/allbert_assist/cli/channels/support.ex
      %{
        "boundary" => "AllbertAssist.Channels.update_event",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 192,
        "roster_id" => "channel-cli-simulation",
        "source_path" => "apps/allbert_assist/lib/allbert_assist/cli/channels/support.ex"
      },
      # apps/allbert_telegram/lib/allbert_telegram/client.ex
      %{
        "boundary" => "Req.request",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 145,
        "roster_id" => "raw-req-plugins-allbert-telegram-lib-allbert-assist-channels-telegram-client-ex",
        "source_path" => "apps/allbert_telegram/lib/allbert_telegram/client.ex"
      },
      %{
        "boundary" => "Req.request",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 178,
        "roster_id" => "raw-req-plugins-allbert-telegram-lib-allbert-assist-channels-telegram-client-ex",
        "source_path" => "apps/allbert_telegram/lib/allbert_telegram/client.ex"
      },
      # apps/allbert_assist/lib/allbert_assist/cli/areas/channels.ex (remaining unclassified)
      %{
        "boundary" => "AllbertAssist.Channels.create_event",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 722,
        "roster_id" => "channel-cli-simulation",
        "source_path" => "apps/allbert_assist/lib/allbert_assist/cli/areas/channels.ex"
      },
      %{
        "boundary" => "AllbertAssist.Runtime.acknowledge_deliveries",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 754,
        "roster_id" => "channel-cli-simulation",
        "source_path" => "apps/allbert_assist/lib/allbert_assist/cli/areas/channels.ex"
      },
      %{
        "boundary" => "AllbertAssist.Runtime.submit_user_input",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 736,
        "roster_id" => "channel-cli-simulation",
        "source_path" => "apps/allbert_assist/lib/allbert_assist/cli/areas/channels.ex"
      },
      %{
        "boundary" => "Req.post",
        "disposition" => "inherited_context",
        "evidence" => "Req call in production effect surface with no explicit epoch check; caller validates epoch.",
        "line" => 842,
        "roster_id" => "",
        "source_path" => "apps/allbert_assist/lib/allbert_assist/cli/areas/channels.ex"
      },
      # apps/allbert_notes_files/lib/allbert_notes_files/cli.ex
      %{
        "boundary" => "AllbertAssist.Actions.Runner.run",
        "disposition" => "external_e1",
        "evidence" => "Reviewed roster source owns or receives the E1 required at this discovered boundary.",
        "line" => 97,
        "roster_id" => "channel-cli-simulation",
        "source_path" => "apps/allbert_notes_files/lib/allbert_notes_files/cli.ex"
      },
    ]

    classifications ++ new_classifications
  end
end

RemapFixture.run()
