defmodule AllbertAssist.CLI.Areas.External do
  @moduledoc """
  Release-safe `external` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.external` and
  `allbert admin external`: `dispatch/2` parses the sub-argv, creates confirmed
  external service requests through the same `external_network_request` action
  the Mix task used, and returns `{rendered_output, exit_code}` — no `Mix.*`
  calls, so it runs inside the packaged release. `Mix.Tasks.Allbert.External` is
  a thin wrapper that prints the output through `Mix.shell/0`.
  """

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Surfaces.ContextBuilder

  @usage """
  Usage:
    allbert admin external request --url URL [--method GET] [--profile NAME]
    allbert admin external request --profile NAME --path /path [--query key=value&...]
  """

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    argv
    |> route(context || default_context())
    |> render()
  end

  defp default_context, do: ContextBuilder.cli_context(surface: "allbert admin external")

  defp route(["request" | args], ctx) do
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
      {:error, "Invalid options: #{inspect(invalid)}"}
    else
      params =
        opts
        |> Map.new()
        |> parse_headers()
        |> parse_query()

      {:ok, response} = Runner.run("external_network_request", params, ctx)
      {:ok, response.message}
    end
  end

  defp route(_args, _ctx), do: {:usage, @usage}

  defp render({:ok, message}) when is_binary(message), do: Render.ok(message)
  defp render({:usage, usage}), do: Render.usage(usage)
  defp render({:error, reason}) when is_binary(reason), do: Render.error(reason)

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
end
