defmodule Mix.Tasks.Allbert.External do
  @moduledoc """
  Create confirmed external service requests.

      mix allbert.external request --url https://example.com/status
      mix allbert.external request --profile test_echo --path /status
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Surfaces.ContextBuilder

  @shortdoc "Create confirmed external service requests"

  @impl Mix.Task
  def run(["request" | args]) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          url: :string,
          profile: :string,
          method: :string,
          path: :string,
          query: :string,
          header: :keep,
          timeout_ms: :integer,
          max_response_bytes: :integer,
          source_text: :string
        ]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    params =
      opts
      |> Map.new()
      |> parse_headers()
      |> parse_query()

    {:ok, response} = Runner.run("external_network_request", params, context())
    Mix.shell().info(response.message)
  end

  def run(_args) do
    Mix.raise("""
    Usage:
      mix allbert.external request --url URL [--method GET] [--profile NAME]
      mix allbert.external request --profile NAME --path /path [--query key=value&...]
    """)
  end

  defp parse_headers(%{header: headers} = params) when is_list(headers) do
    parsed =
      Map.new(headers, fn header ->
        case String.split(header, ":", parts: 2) do
          [name, value] -> {String.trim(name), String.trim(value)}
          [name] -> {String.trim(name), ""}
        end
      end)

    params
    |> Map.delete(:header)
    |> Map.put(:headers, parsed)
  end

  defp parse_headers(params), do: params

  defp parse_query(%{query: query} = params) when is_binary(query) do
    query_params =
      query
      |> String.trim_leading("?")
      |> URI.decode_query()

    Map.put(params, :query, query_params)
  end

  defp parse_query(params), do: params

  defp context do
    ContextBuilder.cli_context(surface: "mix allbert.external")
  end
end
