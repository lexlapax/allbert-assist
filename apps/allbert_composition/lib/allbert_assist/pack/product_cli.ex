defmodule AllbertAssist.Pack.ProductCLI do
  @moduledoc """
  Composition-owned orchestration for packaged and source CLI entries.

  The residual CLI remains the command classifier and renderer. This module
  chooses only among the license, runtime-free, attach, and fail-closed embedded
  paths, so no residual module needs an upward composition dependency.
  """

  alias AllbertAssist.CLI
  alias AllbertAssist.Pack.ProductBootstrap
  alias AllbertAssist.Runtime.Attach

  @not_ready_message "Allbert product is not ready; retry the command."

  @doc "Print one CLI result and halt; packaged launchers call only this entrypoint."
  @spec main([String.t()]) :: no_return()
  def main(argv) do
    CLI.configure_logging()
    {stream, output, code} = run_entry(argv)

    if output != "" do
      case stream do
        :stdout -> IO.puts(output)
        :stderr -> IO.puts(:stderr, output)
      end
    end

    System.halt(code)
  end

  @doc "Run one source or packaged CLI entry without printing or halting."
  @spec run_entry([String.t()]) :: {:stdout | :stderr, String.t(), non_neg_integer()}
  def run_entry(argv) when is_list(argv) do
    plan = CLI.entry_plan(argv)
    run_production_plan(plan, argv)
  end

  defp run_production_plan(%{disposition: :license_view} = plan, _argv),
    do: CLI.run_local(plan, [])

  defp run_production_plan(%{disposition: :runtime_free} = plan, _argv) do
    _ = Application.ensure_all_started(:req)
    CLI.run_local(plan, [])
  end

  defp run_production_plan(%{disposition: :runtime_required} = plan, argv) do
    _ = Application.ensure_all_started(:req)

    case CLI.classify_attach(Attach.run(argv)) do
      {:attached, output, code} ->
        maybe_attach_marker()
        {:stdout, output, code}

      {:error, message} ->
        {:stderr, message, 3}

      :fallback ->
        dispatch_embedded_runtime(plan)
    end
  end

  defp dispatch_embedded_runtime(plan) do
    case ProductBootstrap.ensure_ready([]) do
      {:ok, epoch} -> CLI.run_local(plan, allbert_pack_epoch: epoch)
      {:error, _diagnostic} -> {:stderr, @not_ready_message, 3}
    end
  end

  defp maybe_attach_marker do
    if System.get_env("ALLBERT_ATTACH_DEBUG") in ["1", "true"] do
      IO.puts(:stderr, "allbert: served by the running daemon (attached)")
    end
  end

  if Mix.env() == :test do
    @doc false
    def run_entry_for_test(argv, opts) when is_list(argv) and is_list(opts) do
      cli = Keyword.fetch!(opts, :cli)
      plan = cli.entry_plan(argv)

      run_plan(plan, argv, %{
        cli: cli,
        attach: Keyword.get(opts, :attach, Attach),
        bootstrap: Keyword.get(opts, :bootstrap, ProductBootstrap),
        req_starter: Keyword.get(opts, :req_starter, &Application.ensure_all_started/1)
      })
    end
  end

  defp run_plan(%{disposition: :license_view} = plan, _argv, %{cli: cli}),
    do: cli.run_local(plan, [])

  defp run_plan(%{disposition: :runtime_free} = plan, _argv, %{cli: cli, req_starter: req_starter}) do
    _ = req_starter.(:req)
    cli.run_local(plan, [])
  end

  defp run_plan(%{disposition: :runtime_required} = plan, argv, seams) do
    _ = seams.req_starter.(:req)

    argv
    |> attach_result(seams.attach)
    |> seams.cli.classify_attach()
    |> dispatch_runtime_plan(plan, seams)
  end

  defp attach_result(argv, attach) when is_atom(attach), do: attach.run(argv)
  defp attach_result(argv, attach) when is_function(attach, 1), do: attach.(argv)

  defp dispatch_runtime_plan({:attached, output, code}, _plan, _seams),
    do: {:stdout, output, code}

  defp dispatch_runtime_plan({:error, message}, _plan, _seams),
    do: {:stderr, message, 3}

  defp dispatch_runtime_plan(:fallback, plan, seams) do
    case seams.bootstrap.ensure_ready([]) do
      {:ok, epoch} -> seams.cli.run_local(plan, allbert_pack_epoch: epoch)
      {:error, _diagnostic} -> {:stderr, @not_ready_message, 3}
    end
  end
end
