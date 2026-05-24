defmodule AllbertAssist.Sandbox.SourcePolicy do
  @moduledoc """
  Static defense-in-depth scanner for v0.36 Elixir/OTP sandbox inputs.
  """

  alias AllbertAssist.Paths
  alias AllbertAssist.Sandbox.Bundle

  @rules [
    {:system_cmd, ~r/\bSystem\.(cmd|shell)\s*\(/},
    {:port_open, ~r/\bPort\.open\s*\(/},
    {:os_cmd, ~r/:os\.cmd\s*\(/},
    {:code_eval, ~r/\bCode\.eval_/},
    {:code_compile, ~r/\bCode\.compile_/},
    {:code_require, ~r/\bCode\.require_/},
    {:mix_install, ~r/\bMix\.install\s*\(/},
    {:nif_load, ~r/:erlang\.load_nif\s*\(/},
    {:path_traversal, ~r/\.\.\//},
    {:absolute_user_path, ~r/["']\/(Users|home|private|var)\//}
  ]

  @spec scan(Bundle.t() | [String.t()], keyword()) :: {:ok, map()} | {:error, map()}
  def scan(source, opts \\ [])

  def scan(%Bundle{} = bundle, opts) do
    bundle
    |> bundle_source_files()
    |> scan(opts)
  end

  def scan(paths, _opts) when is_list(paths) do
    diagnostics =
      paths
      |> Enum.flat_map(&scan_file/1)
      |> Enum.map(&redact_diagnostic/1)

    report = %{
      status: if(diagnostics == [], do: :allowed, else: :denied),
      diagnostics: diagnostics
    }

    if diagnostics == [], do: {:ok, report}, else: {:error, report}
  end

  defp bundle_source_files(%Bundle{} = bundle) do
    (bundle.draft_files ++ bundle.test_files)
    |> Enum.map(& &1.target)
    |> Enum.filter(&(&1 && Path.extname(&1) in [".ex", ".exs"]))
  end

  defp scan_file(path) do
    contents = File.read!(path)

    Enum.flat_map(@rules, fn {rule, pattern} ->
      if Regex.match?(pattern, contents) do
        [%{reason: rule, path: path}]
      else
        []
      end
    end)
  rescue
    exception -> [%{reason: :source_read_failed, path: path, error: Exception.message(exception)}]
  end

  defp redact_diagnostic(diagnostic) do
    Map.update(diagnostic, :path, nil, &redact_path/1)
  end

  defp redact_path(path) when is_binary(path) do
    home = Paths.home()

    path
    |> Path.expand()
    |> String.replace(home, "<ALLBERT_HOME>")
  end
end
