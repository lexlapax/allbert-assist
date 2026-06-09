defmodule Mix.Tasks.Allbert.PublicProtocol do
  @moduledoc """
  Manage v0.51 public protocol bearer tokens.

  ## Usage

      mix allbert.public_protocol token create --surface mcp_http --client claude
      mix allbert.public_protocol token rotate --surface openai_api --client local
      mix allbert.public_protocol token revoke --surface mcp_http --client claude
      mix allbert.public_protocol token list --surface openai_api
  """

  use Mix.Task

  alias AllbertAssist.PublicProtocol.TokenAuth

  @shortdoc "Manage public protocol bearer tokens"

  @switches [surface: :string, client: :string]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["token", "create" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    TokenAuth.create(required!(opts, :surface), required!(opts, :client), context())
  end

  defp dispatch(["token", "rotate" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    TokenAuth.rotate(required!(opts, :surface), required!(opts, :client), context())
  end

  defp dispatch(["token", "revoke" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    TokenAuth.revoke(required!(opts, :surface), required!(opts, :client), context())
  end

  defp dispatch(["token", "list" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    TokenAuth.list(required!(opts, :surface))
  end

  defp dispatch(_args), do: usage!()

  defp print_result({:ok, %{token: token} = result}) do
    Mix.shell().info("surface=#{result.surface}")
    Mix.shell().info("client=#{result.client_id}")
    Mix.shell().info("token_ref=#{result.token_ref}")
    Mix.shell().info("token=#{token}")
  end

  defp print_result({:ok, %{status: :revoked} = result}) do
    Mix.shell().info("surface=#{result.surface}")
    Mix.shell().info("client=#{result.client_id}")
    Mix.shell().info("token_ref=#{result.token_ref}")
    Mix.shell().info("token=[REDACTED]")
    Mix.shell().info("status=revoked")
  end

  defp print_result({:ok, clients}) when is_list(clients) do
    Enum.each(clients, fn client ->
      Mix.shell().info(
        "surface=#{client.surface} client=#{client.client_id} enabled=#{client.enabled} token_ref=#{client.token_ref} token=[REDACTED] token_status=#{client.token_status}"
      )
    end)
  end

  defp print_result({:error, reason}) do
    Mix.raise("Public protocol command failed: #{inspect(reason)}")
  end

  defp parse!(args), do: OptionParser.parse(args, strict: @switches)

  defp reject_invalid!([]), do: :ok
  defp reject_invalid!(invalid), do: Mix.raise("Invalid options: #{inspect(invalid)}")

  defp required!(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> value
      _value -> Mix.raise("Missing required --#{String.replace(to_string(key), "_", "-")}")
    end
  end

  defp context, do: %{actor: "operator", channel: "mix", audit?: false}

  defp usage! do
    Mix.raise("""
    Usage:
      mix allbert.public_protocol token create --surface mcp_http|openai_api --client CLIENT
      mix allbert.public_protocol token rotate --surface mcp_http|openai_api --client CLIENT
      mix allbert.public_protocol token revoke --surface mcp_http|openai_api --client CLIENT
      mix allbert.public_protocol token list --surface mcp_http|openai_api
    """)
  end
end
