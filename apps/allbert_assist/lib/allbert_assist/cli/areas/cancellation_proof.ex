defmodule AllbertAssist.CLI.Areas.CancellationProof do
  @moduledoc """
  Release-safe packaged dispatcher for the bounded ADR 0085 proof action.

  It parses one closed mode and delegates to `Actions.Runner`; no process or
  execution logic belongs to the CLI surface.
  """

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Surfaces.ContextBuilder

  @modes ~w(cancel timeout session-escape)
  @usage "Usage: allbert admin cancellation-proof cancel|timeout|session-escape"

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch([mode], context) when mode in @modes do
    context = context || ContextBuilder.cli_context(surface: "allbert admin cancellation-proof")

    case action_runner().("release_cancellation_proof", %{mode: mode}, context) do
      {:ok, %{status: :needs_confirmation} = result} ->
        id = Map.get(result, :confirmation_id)

        {result.message <>
           "\nApprove with:\n  allbert admin confirmations approve #{id}", 1}

      {:ok, result} ->
        code = if result.status == :completed, do: 0, else: 1
        {result.message, code}

      {:error, reason} ->
        {"Cancellation proof failed: #{inspect(reason)}", 1}
    end
  end

  def dispatch(_argv, _context), do: {@usage, 2}

  defp action_runner do
    Application.get_env(:allbert_assist, :cancellation_proof_action_runner, &Runner.run/3)
  end
end
