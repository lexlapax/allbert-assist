defmodule Mix.Tasks.Allbert.Home.Export do
  @moduledoc """
  Export a redacted Allbert Home portability envelope.

  ## Usage

      mix allbert.home.export --out /path/to/home.envelope.json
  """

  use Mix.Task

  alias AllbertAssist.Portability.Export

  @shortdoc "Export a redacted Allbert Home portability envelope"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> parse!()
    |> export!()
  end

  defp parse!(args) do
    case OptionParser.parse(args, strict: [out: :string]) do
      {opts, [], []} ->
        out = Keyword.get(opts, :out)
        if is_binary(out) and out != "", do: %{out: out}, else: Mix.raise(usage())

      {_opts, _rest, invalid} when invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      _other ->
        Mix.raise(usage())
    end
  end

  defp export!(%{out: out}) do
    with {:ok, envelope} <- Export.build(),
         :ok <- write_json(out, envelope) do
      Mix.shell().info("Exported Allbert Home envelope")
      Mix.shell().info("Envelope: #{out}")
      Mix.shell().info("envelope_version=#{envelope["envelope_version"]}")
      Mix.shell().info("fragments=#{length(get_in(envelope, ["settings", "fragments"]))}")
      Mix.shell().info("files=#{get_in(envelope, ["manifest", "home", "file_count"])}")
      Mix.shell().info("secret_refs=#{length(envelope["secret_references"])}")
      Mix.shell().info("redacted=true")
      :ok
    else
      {:error, reason} -> Mix.raise("Home export failed: #{inspect(reason)}")
    end
  end

  defp write_json(path, envelope) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write(path, Jason.encode!(envelope, pretty: true))
  end

  defp usage do
    """
    Usage:
      mix allbert.home.export --out PATH
    """
  end
end
