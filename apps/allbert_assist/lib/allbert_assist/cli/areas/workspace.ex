defmodule AllbertAssist.CLI.Areas.Workspace do
  @moduledoc """
  Release-safe `workspace` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.workspace` and
  `allbert admin workspace`: `dispatch/2` parses the sub-argv, performs the same
  workspace reads/maintenance the Mix task did, and returns
  `{rendered_output, exit_code}` — no `Mix.*` calls, so it runs inside the
  packaged release. `Mix.Tasks.Allbert.Workspace` is a thin wrapper that prints
  the output through `Mix.shell/0`. Operand/validation failures that the Mix task
  raised via `Mix.raise/1` become error/usage exit codes here.
  """

  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Surfaces.ContextBuilder
  alias AllbertAssist.Workspace
  alias AllbertAssist.Workspace.Catalog
  alias AllbertAssist.Workspace.Fragment.SigningSecret

  @usage """
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
  """

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    argv
    |> route(context || default_context())
    |> render()
  end

  defp default_context, do: ContextBuilder.cli_context(surface: "allbert admin workspace")

  defp route(argv, ctx) do
    do_route(argv, ctx)
  catch
    {:workspace_error, message} -> {:error, {:raw, message}}
  end

  defp do_route(["rotate-signing-secret"], _ctx) do
    with {:ok, result} <- SigningSecret.rotate() do
      {:ok, {:rotate, result}}
    end
  end

  defp do_route(["inspect" | args], _ctx) do
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

  defp do_route(["canvas", "list" | args], _ctx) do
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

  defp do_route(["canvas", "show", tile_id | args], _ctx) do
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

  defp do_route(["canvas", action, tile_id | args], _ctx)
       when action in ["pin", "unpin", "restore"] do
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

  defp do_route(["canvas", "purge" | args], _ctx) do
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

  defp do_route(["ephemeral", "list" | args], _ctx) do
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

  defp do_route(_args, _ctx), do: {:usage, @usage}

  defp render({:ok, {:rotate, result}}) do
    Render.ok([
      "Rotated workspace fragment signing secret.",
      "Path: #{result.path}",
      "Fingerprint: #{result.fingerprint}",
      "Rotated at: #{DateTime.to_iso8601(result.rotated_at)}",
      "Previous secret accepted until: #{DateTime.to_iso8601(result.previous_expires_at)}",
      "Overlap seconds: #{result.overlap_seconds}"
    ])
  end

  defp render({:ok, {:inspect, opts}}) do
    user_id = Keyword.get(opts, :user, "local")
    thread_id = Keyword.get(opts, :thread, "local-default")
    surface = Catalog.workspace_tree(user_id: user_id, thread_id: thread_id)

    Render.ok(
      [
        "Resolved workspace Surface tree",
        "Surface: #{inspect(surface.id)} #{surface.path} kind=#{surface.kind}",
        "workspace.theme.mode=#{workspace_theme()}",
        "user_id=#{user_id} thread_id=#{thread_id}"
      ] ++ Enum.flat_map(surface.nodes, &node_lines(&1, 0))
    )
  end

  defp render({:ok, {:canvas_list, []}}), do: Render.ok("No canvas tiles.")

  defp render({:ok, {:canvas_list, tiles}}) do
    Render.ok(
      Enum.map(tiles, fn tile ->
        "#{tile.id} thread=#{tile.thread_id} kind=#{tile.kind} pinned=#{tile.pinned} deleted=#{deleted?(tile)} read_only=#{tile.read_only} position=#{tile.position}"
      end)
    )
  end

  defp render({:ok, {:canvas_show, tile}}) do
    Render.ok([
      "Tile: #{tile.id}",
      "User: #{tile.user_id}",
      "Thread: #{tile.thread_id}",
      "Kind: #{tile.kind}",
      "Position: #{tile.position}",
      "Pinned: #{tile.pinned}",
      "Deleted: #{deleted?(tile)}",
      "Deleted at: #{time_text(tile.deleted_at)}",
      "Read only: #{tile.read_only}",
      "Body path: #{tile.body_yaml_path}",
      "Body:",
      inspect(Redactor.redact(tile.body), pretty: true, limit: :infinity)
    ])
  end

  defp render({:ok, {:canvas_pin, tile}}), do: Render.ok("Pinned canvas tile: #{tile.id}")
  defp render({:ok, {:canvas_unpin, tile}}), do: Render.ok("Unpinned canvas tile: #{tile.id}")
  defp render({:ok, {:canvas_restore, tile}}), do: Render.ok("Restored canvas tile: #{tile.id}")

  defp render({:ok, {:canvas_purge, purged, before}}) do
    Render.ok(
      ["Purged canvas tiles before #{DateTime.to_iso8601(before)}: #{length(purged)}"] ++
        Enum.map(purged, fn tile -> "- #{tile.id}" end)
    )
  end

  defp render({:ok, {:ephemeral_list, []}}), do: Render.ok("No ephemeral surfaces.")

  defp render({:ok, {:ephemeral_list, surfaces}}) do
    Render.ok(
      Enum.map(surfaces, fn surface ->
        "#{surface.id} thread=#{surface.thread_id} kind=#{surface.kind} pinned=#{surface.pinned} dismissed=#{dismissed?(surface)} dismissed_by=#{dismissed_by(surface)} opened=#{time_text(surface.opened_at)}"
      end)
    )
  end

  defp render({:usage, usage}), do: Render.usage(usage)
  defp render({:error, {:raw, message}}), do: Render.error(message)
  defp render({:error, reason}), do: Render.error("Workspace command failed: #{inspect(reason)}")

  defp workspace_theme do
    case Settings.get("workspace.theme.mode") do
      {:ok, theme} -> theme
      _other -> "system"
    end
  end

  defp user_id!(opts) do
    user = blank_to_nil(opts[:user])
    operator = blank_to_nil(opts[:operator])

    cond do
      user && operator && user != operator ->
        fail("--user and --operator must match when both are provided")

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
  defp reject_invalid!(invalid), do: fail("Invalid option(s): #{inspect(invalid)}")

  defp reject_rest!([], _command), do: :ok

  defp reject_rest!(rest, command) do
    fail("Unexpected argument(s) for #{command}: #{Enum.join(rest, " ")}")
  end

  defp parse_before!(nil), do: fail("canvas purge requires --before")

  defp parse_before!(value) do
    value = String.trim(value)

    with {:error, _date_error} <- parse_date_before(value),
         {:error, _datetime_error} <- parse_datetime_before(value),
         {:error, _naive_error} <- parse_naive_before(value) do
      fail("--before must be an ISO date or datetime")
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

  defp node_lines(%Node{} = node, depth) do
    indent = String.duplicate("  ", depth)

    ["#{indent}- #{node.id} #{node.component}"] ++
      Enum.flat_map(node.children, &node_lines(&1, depth + 1))
  end

  @spec fail(String.t()) :: no_return()
  defp fail(message), do: throw({:workspace_error, message})
end
