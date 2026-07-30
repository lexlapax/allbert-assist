defmodule AllbertAssist.CLI.Areas.Search do
  @moduledoc """
  Thin packaged CLI consumer for the central Search command boundary.
  """

  alias AllbertAssist.Search.Surface
  alias AllbertAssist.Surface.Renderer
  alias AllbertAssist.Surfaces.ContextBuilder

  @descriptor %{
    primitives: [:typed_command, :list],
    threading: :reply_chain,
    payload: :surface_payload,
    approval_text: :typed_and_list,
    typed_intro: "Type one exact command:",
    list_intro: "Approval options:"
  }

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    context = context || ContextBuilder.cli_context(%{surface: "cli", channel: :cli})
    {:ok, response} = Surface.dispatch_argv(argv, context)
    {:ok, rendered} = Renderer.render_response(response, @descriptor)

    text = maybe_append_confirmation_guidance(rendered.text, response)
    {text, exit_code(response)}
  end

  defp maybe_append_confirmation_guidance(text, %{status: :needs_confirmation}) do
    text <>
      "\n\nApprove or deny with `allbert admin confirmations`; then resubmit the exact Search query with --chain <ID>."
  end

  defp maybe_append_confirmation_guidance(text, _response), do: text

  defp exit_code(%{status: status}) when status in [:completed, :advisory], do: 0
  defp exit_code(_response), do: 1
end
