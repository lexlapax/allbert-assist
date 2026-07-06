defmodule AllbertAssist.CLI.Areas.PublicProtocol do
  @moduledoc """
  Release-safe `public_protocol` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.public_protocol` and
  `allbert admin public_protocol`: `dispatch/2` parses the sub-argv, routes to
  the same `PublicProtocol.TokenAuth` operations the Mix task used, and returns
  `{rendered_output, exit_code}` — no `Mix.*` calls, so it runs inside the
  packaged release. `Mix.Tasks.Allbert.PublicProtocol` is a thin wrapper that
  prints the output through `Mix.shell/0`.

  Token issuance/rotation/revocation mutate Settings-Secrets state, so
  (v0.62 M8.15) they run through the action Runner — `create_protocol_token`,
  `rotate_protocol_token`, `revoke_protocol_token` — which enforces the
  PermissionGate + audit spine. `token list` is a pure read and still calls
  `TokenAuth.list/1` directly. The registered actions return the raw token
  under a `token`-named field so the CLI can print it once; that field name is
  redacted in every logged signal and audit record.
  """

  alias AllbertAssist.Actions.ErrorExtraction
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.PublicProtocol.TokenAuth
  alias AllbertAssist.Surfaces.ContextBuilder

  @switches [surface: :string, client: :string]

  @usage """
  Usage:
    mix allbert.public_protocol token create --surface mcp_http|openai_api --client CLIENT
    mix allbert.public_protocol token rotate --surface mcp_http|openai_api --client CLIENT
    mix allbert.public_protocol token revoke --surface mcp_http|openai_api --client CLIENT
    mix allbert.public_protocol token list --surface mcp_http|openai_api
  """

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    argv
    |> route(context || default_context())
    |> render()
  end

  defp default_context do
    ContextBuilder.cli_context(
      actor: "operator",
      user_id: "operator",
      surface: "allbert admin public_protocol"
    )
  end

  defp route(["token", "create" | rest], ctx) do
    with {:ok, opts} <- parse(rest),
         {:ok, surface} <- required(opts, :surface),
         {:ok, client} <- required(opts, :client) do
      run_token_action("create_protocol_token", surface, client, ctx)
    end
  end

  defp route(["token", "rotate" | rest], ctx) do
    with {:ok, opts} <- parse(rest),
         {:ok, surface} <- required(opts, :surface),
         {:ok, client} <- required(opts, :client) do
      run_token_action("rotate_protocol_token", surface, client, ctx)
    end
  end

  defp route(["token", "revoke" | rest], ctx) do
    with {:ok, opts} <- parse(rest),
         {:ok, surface} <- required(opts, :surface),
         {:ok, client} <- required(opts, :client) do
      run_token_action("revoke_protocol_token", surface, client, ctx)
    end
  end

  defp route(["token", "list" | rest], _ctx) do
    with {:ok, opts} <- parse(rest),
         {:ok, surface} <- required(opts, :surface) do
      TokenAuth.list(surface)
    end
  end

  defp route(_args, _ctx), do: {:usage, @usage}

  # Mutations go on-spine: the Runner enforces PermissionGate + audit and
  # returns the TokenAuth result under `token_result`. Unwrapping it here keeps
  # the existing `{:ok, token_map}` render clauses (and their exact output).
  defp run_token_action(name, surface, client, ctx) do
    case Runner.run(name, %{surface: surface, client: client}, ctx) do
      {:ok, %{status: :completed, token_result: result}} ->
        {:ok, result}

      {:ok, response} ->
        {:error, {:action_failed, ErrorExtraction.from_response(response)}}
    end
  end

  defp render({:ok, %{token: token} = result}) do
    Render.ok([
      "surface=#{result.surface}",
      "client=#{result.client_id}",
      "token_ref=#{result.token_ref}",
      "token=#{token}"
    ])
  end

  defp render({:ok, %{status: :revoked} = result}) do
    Render.ok([
      "surface=#{result.surface}",
      "client=#{result.client_id}",
      "token_ref=#{result.token_ref}",
      "token=[REDACTED]",
      "status=revoked"
    ])
  end

  defp render({:ok, clients}) when is_list(clients) do
    Render.ok(
      Enum.map(clients, fn client ->
        "surface=#{client.surface} client=#{client.client_id} enabled=#{client.enabled} token_ref=#{client.token_ref} token=[REDACTED] token_status=#{client.token_status}"
      end)
    )
  end

  defp render({:usage, usage}), do: Render.usage(usage)

  defp render({:error, {:invalid_options, invalid}}) do
    Render.error("Invalid options: #{inspect(invalid)}")
  end

  defp render({:error, {:missing_required, key}}) do
    Render.error("Missing required --#{String.replace(to_string(key), "_", "-")}")
  end

  defp render({:error, {:action_failed, reason}}) do
    Render.error("Public protocol command failed: #{inspect(reason)}")
  end

  defp render({:error, reason}) do
    Render.error("Public protocol command failed: #{inspect(reason)}")
  end

  defp parse(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} -> {:ok, opts}
      {_opts, _positionals, invalid} -> {:error, {:invalid_options, invalid}}
    end
  end

  defp required(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing_required, key}}
    end
  end
end
