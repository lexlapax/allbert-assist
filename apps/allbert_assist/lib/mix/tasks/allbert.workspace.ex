defmodule Mix.Tasks.Allbert.Workspace do
  @moduledoc """
  Inspect and maintain the Allbert workspace substrate.

  ## Usage

      mix allbert.workspace rotate-signing-secret
      mix allbert.workspace inspect [--user USER] [--thread THREAD]
      mix allbert.workspace canvas list [--user USER] [--thread THREAD] [--include-deleted]
      mix allbert.workspace canvas show TILE_ID [--user USER]
      mix allbert.workspace canvas pin TILE_ID [--user USER]
      mix allbert.workspace canvas unpin TILE_ID [--user USER]
      mix allbert.workspace canvas restore TILE_ID [--user USER]
      mix allbert.workspace canvas purge --before YYYY-MM-DD [--user USER]
      mix allbert.workspace ephemeral list [--user USER] [--thread THREAD] [--include-dismissed]
  """

  use Mix.Task

  alias AllbertAssist.Security.Redactor
  alias AllbertAssist.Settings
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace
  alias AllbertAssist.Workspace.Catalog
  alias AllbertAssist.Workspace.Fragment.SigningSecret

  @shortdoc "Inspect and maintain the Allbert workspace substrate"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["rotate-signing-secret"]) do
    SigningSecret.rotate()
  end

  defp dispatch(["inspect" | args]) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [user: :string, operator: :string, thread: :string],
        aliases: aliases()
      )

    case invalid do
      [] -> {:ok, {:inspect, opts}}
      _invalid -> {:error, :invalid_inspect_options}
    end
  end

  defp dispatch(["canvas", "list" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [user: :string, operator: :string, thread: :string, include_deleted: :boolean],
        aliases: aliases()
      )

    reject_invalid!(invalid)
    reject_rest!(rest, "canvas list")

    user_id = user_id!(opts)
    thread_id = thread_id!(opts)

    with {:ok, tiles} <-
           Workspace.canvas_tiles(thread_id, user_id,
             include_deleted: Keyword.get(opts, :include_deleted, false)
           ) do
      {:ok, {:canvas_list, tiles}}
    end
  end

  defp dispatch(["canvas", "show", tile_id | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [user: :string, operator: :string],
        aliases: aliases()
      )

    reject_invalid!(invalid)
    reject_rest!(rest, "canvas show")

    with {:ok, tile} <- Workspace.get_tile(tile_id, user_id!(opts), include_deleted: true) do
      {:ok, {:canvas_show, tile}}
    end
  end

  defp dispatch(["canvas", action, tile_id | args]) when action in ["pin", "unpin", "restore"] do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [user: :string, operator: :string],
        aliases: aliases()
      )

    reject_invalid!(invalid)
    reject_rest!(rest, "canvas #{action}")

    user_id = user_id!(opts)

    case action do
      "pin" -> Workspace.pin_tile(tile_id, user_id)
      "unpin" -> Workspace.unpin_tile(tile_id, user_id)
      "restore" -> Workspace.restore_tile(tile_id, user_id)
    end
    |> case do
      {:ok, tile} -> {:ok, {:"canvas_#{action}", tile}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch(["canvas", "purge" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [user: :string, operator: :string, before: :string],
        aliases: aliases()
      )

    reject_invalid!(invalid)
    reject_rest!(rest, "canvas purge")

    before = parse_before!(opts[:before])

    with {:ok, purged} <- Workspace.purge_deleted_tiles(user_id!(opts), before) do
      {:ok, {:canvas_purge, purged, before}}
    end
  end

  defp dispatch(["ephemeral", "list" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [user: :string, operator: :string, thread: :string, include_dismissed: :boolean],
        aliases: aliases()
      )

    reject_invalid!(invalid)
    reject_rest!(rest, "ephemeral list")

    user_id = user_id!(opts)
    thread_id = thread_id!(opts)

    with {:ok, surfaces} <-
           Workspace.ephemeral_surfaces(thread_id, user_id,
             include_dismissed: Keyword.get(opts, :include_dismissed, false)
           ) do
      {:ok, {:ephemeral_list, surfaces}}
    end
  end

  defp dispatch(_args) do
    Mix.raise("""
    Usage:
      mix allbert.workspace rotate-signing-secret
      mix allbert.workspace inspect [--user USER] [--thread THREAD]
      mix allbert.workspace canvas list [--user USER] [--thread THREAD] [--include-deleted]
      mix allbert.workspace canvas show TILE_ID [--user USER]
      mix allbert.workspace canvas pin TILE_ID [--user USER]
      mix allbert.workspace canvas unpin TILE_ID [--user USER]
      mix allbert.workspace canvas restore TILE_ID [--user USER]
      mix allbert.workspace canvas purge --before YYYY-MM-DD [--user USER]
      mix allbert.workspace ephemeral list [--user USER] [--thread THREAD] [--include-dismissed]
    """)
  end

  defp print_result({:ok, {:inspect, opts}}) do
    user_id = Keyword.get(opts, :user, "local")
    thread_id = Keyword.get(opts, :thread, "local-default")
    surface = Catalog.workspace_tree(user_id: user_id, thread_id: thread_id)

    Mix.shell().info("Resolved workspace Surface tree")
    Mix.shell().info("Surface: #{inspect(surface.id)} #{surface.path} kind=#{surface.kind}")
    Mix.shell().info("workspace.theme=#{workspace_theme()}")
    Mix.shell().info("user_id=#{user_id} thread_id=#{thread_id}")

    Enum.each(surface.nodes, &print_node(&1, 0))
  end

  defp print_result({:ok, {:canvas_list, []}}) do
    Mix.shell().info("No canvas tiles.")
  end

  defp print_result({:ok, {:canvas_list, tiles}}) do
    Enum.each(tiles, fn tile ->
      Mix.shell().info(
        "#{tile.id} thread=#{tile.thread_id} kind=#{tile.kind} pinned=#{tile.pinned} deleted=#{deleted?(tile)} read_only=#{tile.read_only} position=#{tile.position}"
      )
    end)
  end

  defp print_result({:ok, {:canvas_show, tile}}) do
    Mix.shell().info("Tile: #{tile.id}")
    Mix.shell().info("User: #{tile.user_id}")
    Mix.shell().info("Thread: #{tile.thread_id}")
    Mix.shell().info("Kind: #{tile.kind}")
    Mix.shell().info("Position: #{tile.position}")
    Mix.shell().info("Pinned: #{tile.pinned}")
    Mix.shell().info("Deleted: #{deleted?(tile)}")
    Mix.shell().info("Deleted at: #{time_text(tile.deleted_at)}")
    Mix.shell().info("Read only: #{tile.read_only}")
    Mix.shell().info("Body path: #{tile.body_yaml_path}")
    Mix.shell().info("Body:")
    Mix.shell().info(inspect(Redactor.redact(tile.body), pretty: true, limit: :infinity))
  end

  defp print_result({:ok, {:canvas_pin, tile}}) do
    Mix.shell().info("Pinned canvas tile: #{tile.id}")
  end

  defp print_result({:ok, {:canvas_unpin, tile}}) do
    Mix.shell().info("Unpinned canvas tile: #{tile.id}")
  end

  defp print_result({:ok, {:canvas_restore, tile}}) do
    Mix.shell().info("Restored canvas tile: #{tile.id}")
  end

  defp print_result({:ok, {:canvas_purge, purged, before}}) do
    Mix.shell().info(
      "Purged canvas tiles before #{DateTime.to_iso8601(before)}: #{length(purged)}"
    )

    Enum.each(purged, fn tile ->
      Mix.shell().info("- #{tile.id}")
    end)
  end

  defp print_result({:ok, {:ephemeral_list, []}}) do
    Mix.shell().info("No ephemeral surfaces.")
  end

  defp print_result({:ok, {:ephemeral_list, surfaces}}) do
    Enum.each(surfaces, fn surface ->
      Mix.shell().info(
        "#{surface.id} thread=#{surface.thread_id} kind=#{surface.kind} pinned=#{surface.pinned} dismissed=#{dismissed?(surface)} dismissed_by=#{dismissed_by(surface)} opened=#{time_text(surface.opened_at)}"
      )
    end)
  end

  defp print_result({:ok, result}) when is_map(result) do
    Mix.shell().info("Rotated workspace fragment signing secret.")
    Mix.shell().info("Path: #{result.path}")
    Mix.shell().info("Fingerprint: #{result.fingerprint}")
    Mix.shell().info("Rotated at: #{DateTime.to_iso8601(result.rotated_at)}")

    Mix.shell().info(
      "Previous secret accepted until: #{DateTime.to_iso8601(result.previous_expires_at)}"
    )

    Mix.shell().info("Overlap seconds: #{result.overlap_seconds}")
  end

  defp print_result({:error, reason}) do
    Mix.raise("Workspace command failed: #{inspect(reason)}")
  end

  defp workspace_theme do
    case Settings.get("workspace.theme") do
      {:ok, theme} -> theme
      _other -> "system"
    end
  end

  defp user_id!(opts) do
    user = blank_to_nil(opts[:user])
    operator = blank_to_nil(opts[:operator])

    cond do
      user && operator && user != operator ->
        Mix.raise("--user and --operator must match when both are provided")

      user ->
        user

      operator ->
        operator

      true ->
        "local"
    end
  end

  defp thread_id!(opts), do: blank_to_nil(opts[:thread]) || "local-default"

  defp reject_invalid!([]), do: :ok
  defp reject_invalid!(invalid), do: Mix.raise("Invalid option(s): #{inspect(invalid)}")

  defp reject_rest!([], _command), do: :ok

  defp reject_rest!(rest, command) do
    Mix.raise("Unexpected argument(s) for #{command}: #{Enum.join(rest, " ")}")
  end

  defp parse_before!(nil), do: Mix.raise("canvas purge requires --before")

  defp parse_before!(value) do
    value = String.trim(value)

    with {:error, _date_error} <- parse_date_before(value),
         {:error, _datetime_error} <- parse_datetime_before(value),
         {:error, _naive_error} <- parse_naive_before(value) do
      Mix.raise("--before must be an ISO date or datetime")
    else
      {:ok, before} -> before
    end
  end

  defp parse_date_before(value) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        {:ok, DateTime.from_naive!(NaiveDateTime.new!(date, ~T[00:00:00]), "Etc/UTC")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_datetime_before(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_naive_before(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} -> {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp aliases, do: [u: :user, o: :operator, t: :thread]

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp deleted?(tile), do: not is_nil(tile.deleted_at)
  defp dismissed?(surface), do: not is_nil(surface.dismissed_at)
  defp dismissed_by(%{dismissed_by: nil}), do: "active"
  defp dismissed_by(%{dismissed_by: dismissed_by}), do: dismissed_by

  defp time_text(nil), do: "none"
  defp time_text(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp time_text(%NaiveDateTime{} = timestamp), do: NaiveDateTime.to_iso8601(timestamp)
  defp time_text(timestamp), do: to_string(timestamp)

  defp print_node(%Node{} = node, depth) do
    indent = String.duplicate("  ", depth)
    Mix.shell().info("#{indent}- #{node.id} #{node.component}")
    Enum.each(node.children, &print_node(&1, depth + 1))
  end
end
