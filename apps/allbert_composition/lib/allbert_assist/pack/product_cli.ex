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
    run_plan(plan, argv, default_seams())
  end

  # Production and the test entry ran two parallel copies of this dispatch, and
  # they had already drifted: only the production copy emitted the attach
  # marker, so the tests were exercising an implementation the packaged binary
  # never runs. There is now one implementation, and production is simply the
  # default set of seams.
  defp default_seams do
    %{
      cli: CLI,
      attach: Attach,
      bootstrap: ProductBootstrap,
      req_starter: &Application.ensure_all_started/1
    }
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

  # v1.4 M13.3: the function form is a test seam and now exists only where it is
  # used. A shipped build always passes the module, so this clause was
  # unreachable there -- one of the six findings that appeared the moment
  # dialyzer ran against the build being shipped instead of the one being tested.
  # Compiled out rather than suppressed: a seam that cannot be reached in
  # production should not be in production.
  if Mix.env() == :test do
    defp attach_result(argv, attach) when is_function(attach, 1), do: attach.(argv)
  end

  defp dispatch_runtime_plan({:attached, output, code}, _plan, _seams) do
    maybe_attach_marker()
    {:stdout, output, code}
  end

  defp dispatch_runtime_plan({:error, message}, _plan, _seams),
    do: {:stderr, message, 3}

  defp dispatch_runtime_plan(:fallback, plan, seams) do
    case seams.bootstrap.ensure_ready([]) do
      {:ok, epoch} -> seams.cli.run_local(plan, allbert_pack_epoch: epoch)
      {:error, _diagnostic} -> {:stderr, @not_ready_message, 3}
    end
  end
end
