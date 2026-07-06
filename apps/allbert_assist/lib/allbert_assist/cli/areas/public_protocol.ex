defmodule AllbertAssist.CLI.Areas.PublicProtocol do
  @moduledoc """
  Release-safe `public_protocol` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.public_protocol` and
  `allbert admin public_protocol`: `dispatch/2` parses the sub-argv, routes to
  the same `PublicProtocol.TokenAuth` operations the Mix task used, and returns
  `{rendered_output, exit_code}` — no `Mix.*` calls, so it runs inside the
  packaged release. `Mix.Tasks.Allbert.PublicProtocol` is a thin wrapper that
  prints the output through `Mix.shell/0`.

  The default context preserves the original task's audit-sensitive identity
  (operator actor, `audit?: false`); token issuance/rotation/revocation is a
  privileged operator operation, so this deviates from the generic
  `surface: "allbert admin <area>"` default on purpose.
  """

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
      channel: "mix",
      surface: "mix allbert.public_protocol",
      audit?: false
    )
  end

  defp route(["token", "create" | rest], ctx) do
    with {:ok, opts} <- parse(rest),
         {:ok, surface} <- required(opts, :surface),
         {:ok, client} <- required(opts, :client) do
      TokenAuth.create(surface, client, ctx)
    end
  end

  defp route(["token", "rotate" | rest], ctx) do
    with {:ok, opts} <- parse(rest),
         {:ok, surface} <- required(opts, :surface),
         {:ok, client} <- required(opts, :client) do
      TokenAuth.rotate(surface, client, ctx)
    end
  end

  defp route(["token", "revoke" | rest], ctx) do
    with {:ok, opts} <- parse(rest),
         {:ok, surface} <- required(opts, :surface),
         {:ok, client} <- required(opts, :client) do
      TokenAuth.revoke(surface, client, ctx)
    end
  end

  defp route(["token", "list" | rest], _ctx) do
    with {:ok, opts} <- parse(rest),
         {:ok, surface} <- required(opts, :surface) do
      TokenAuth.list(surface)
    end
  end

  defp route(_args, _ctx), do: {:usage, @usage}

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
