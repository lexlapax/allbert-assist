defmodule AllbertAssist.CLI.Areas.Notes do
  @moduledoc """
  Release-safe `notes` admin dispatch (v0.65 M2).

  The single source of truth for `mix allbert.notes` and `allbert admin notes`:
  `dispatch/2` parses the sub-argv, routes to the registered `set_notes_root` /
  `read_setting` actions, and returns `{rendered_output, exit_code}` — no `Mix.*`
  calls, so it runs inside the packaged release. `set-root` is the config-free
  "connect a notes folder" product path (v0.65 Locked Decision 2); the generic
  `allbert admin settings set apps.notes_files.notes_root PATH` remains a low-level
  fallback.
  """

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Surfaces.ContextBuilder

  @notes_root_key "apps.notes_files.notes_root"

  @usage """
  Usage:
    mix allbert.notes set-root PATH [--user USER]
    mix allbert.notes show [--user USER]

  set-root connects a local notes folder (PATH must be an existing directory).
  """

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    argv
    |> route(context || default_context())
    |> render()
  end

  defp default_context, do: ContextBuilder.cli_context(surface: "allbert admin notes")

  # -- routing ---------------------------------------------------------------

  defp route([], _ctx), do: {:usage, @usage}
  defp route(["help" | _], _ctx), do: {:usage, @usage}
  defp route(["--help" | _], _ctx), do: {:usage, @usage}

  defp route(["set-root", path | args], ctx) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [user: :string, operator: :string])

    with :ok <- reject_invalid(invalid),
         :ok <- reject_rest(rest, "set-root"),
         {:ok, user_id} <- resolve_user_id(opts),
         {:ok, response} <-
           completed_action("set_notes_root", %{path: path}, ctx, user_id) do
      {:ok, {:root_set, response}}
    end
  end

  defp route(["set-root"], _ctx), do: {:error, {:arg, "set-root requires a PATH."}}

  defp route(["show" | args], ctx) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [user: :string, operator: :string])

    with :ok <- reject_invalid(invalid),
         :ok <- reject_rest(rest, "show"),
         {:ok, user_id} <- resolve_user_id(opts),
         {:ok, response} <-
           completed_action("read_setting", %{key: @notes_root_key}, ctx, user_id) do
      {:ok, {:root, response}}
    end
  end

  defp route(other, _ctx), do: {:error, {:arg, "Unknown notes command: #{inspect(other)}"}}

  # -- rendering -------------------------------------------------------------

  defp render({:ok, {:root_set, response}}), do: Render.ok(response.message)

  defp render({:ok, {:root, response}}) do
    Render.ok("Notes root: #{setting_value(response)}")
  end

  defp render({:usage, usage}), do: Render.usage(usage)
  defp render({:error, {:arg, message}}), do: Render.error(message)
  defp render({:error, {:action, message}}), do: Render.error(message)

  # -- helpers ---------------------------------------------------------------

  defp setting_value(%{setting: %{value: value}}), do: value
  defp setting_value(%{value: value}), do: value
  defp setting_value(_response), do: "unset"

  # Surface the action's own operator-facing message on a non-completed (denied) response,
  # rather than an extracted error atom.
  defp completed_action(action_name, params, ctx, user_id) do
    case Runner.run(action_name, params, context(ctx, user_id)) do
      {:ok, %{status: :completed} = response} -> {:ok, response}
      {:ok, %{message: message}} -> {:error, {:action, message}}
      {:ok, response} -> {:error, {:action, inspect(response)}}
    end
  end

  defp context(ctx, user_id) do
    ContextBuilder.cli_context(
      actor: user_id,
      user_id: user_id,
      operator_id: user_id,
      surface: Map.get(ctx, :surface) || "allbert admin notes"
    )
  end

  defp resolve_user_id(opts) do
    user = opts[:user]
    operator = opts[:operator]

    cond do
      present?(user) and present?(operator) and user != operator ->
        {:error, {:arg, "--user and --operator must match when both are provided."}}

      present?(user) ->
        {:ok, user}

      present?(operator) ->
        {:ok, operator}

      true ->
        {:ok, "local"}
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp reject_invalid([]), do: :ok
  defp reject_invalid(invalid), do: {:error, {:arg, "Unknown options: #{inspect(invalid)}"}}

  defp reject_rest([], _command), do: :ok

  defp reject_rest(rest, command),
    do: {:error, {:arg, "Unexpected #{command} arguments: #{inspect(rest)}"}}
end
