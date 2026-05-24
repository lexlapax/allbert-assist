defmodule AllbertAssist.Theme.Status do
  @moduledoc """
  Read-only accountability status for v0.35 file-backed workspace overrides.

  Settings Central owns the gates and selections; this module inspects the
  corresponding Allbert Home files without storing their contents as settings.
  """

  alias AllbertAssist.Theme.Layout
  alias AllbertAssist.Theme.Snippets
  alias AllbertAssist.Theme.Tokens

  @max_diagnostics 8
  @max_message_length 180

  @type status :: %{
          token: map(),
          snippets: map(),
          layout: map(),
          diagnostics: [String.t()]
        }

  @spec summary() :: status()
  def summary do
    {token, token_diagnostics} = token_status()
    {snippets, snippet_diagnostics} = snippets_status()
    {layout, layout_diagnostics} = layout_status()

    %{
      token: token,
      snippets: snippets,
      layout: layout,
      diagnostics: cap_diagnostics(token_diagnostics ++ snippet_diagnostics ++ layout_diagnostics)
    }
  end

  defp token_status do
    status = Tokens.selected()

    {Map.drop(status, [:declarations, :diagnostics]), status.diagnostics}
  end

  defp snippets_status do
    status = Snippets.selected()

    {Map.drop(status, [:css, :diagnostics]), status.diagnostics}
  end

  defp layout_status do
    layout = Layout.current()

    {Map.drop(layout, [:diagnostics, :panel_pins]), layout.diagnostics}
  end

  defp cap_diagnostics(diagnostics) do
    diagnostics
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.slice(to_string(&1), 0, @max_message_length))
    |> Enum.take(@max_diagnostics)
  end
end
