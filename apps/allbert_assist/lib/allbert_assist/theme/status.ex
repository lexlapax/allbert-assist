defmodule AllbertAssist.Theme.Status do
  @moduledoc """
  Read-only accountability status for v0.35 file-backed workspace overrides.

  Settings Central owns the gates and selections; this module inspects the
  corresponding Allbert Home files without storing their contents as settings.
  """

  alias AllbertAssist.Runtime.Paths
  alias AllbertAssist.Settings
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
    enabled? = setting("workspace.layout.override_enabled", false)
    path = Path.join(Paths.workspace_root(), "layout.yaml")

    if enabled? do
      {status, diagnostics} = file_status(path, "layout.yaml", :layout)
      {Map.put(status, :enabled?, true), diagnostics}
    else
      {%{
         enabled?: false,
         basename: "layout.yaml",
         fingerprint: nil,
         mtime: nil,
         status: :disabled
       }, []}
    end
  end

  defp file_status(path, basename, kind) do
    cond do
      not File.exists?(path) ->
        {%{basename: basename, fingerprint: nil, mtime: nil, status: :missing},
         ["#{label(kind)} file #{basename} is missing."]}

      File.dir?(path) ->
        {%{basename: basename, fingerprint: nil, mtime: nil, status: :invalid},
         ["#{label(kind)} file #{basename} is a directory."]}

      true ->
        {%{
           basename: basename,
           fingerprint: fingerprint(path),
           mtime: mtime(path),
           status: :present
         }, []}
    end
  end

  defp setting(key, default) do
    case Settings.get(key) do
      {:ok, value} -> value
      _other -> default
    end
  end

  defp fingerprint(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  rescue
    _exception -> nil
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      _other -> nil
    end
  end

  defp label(:token), do: "Token theme"
  defp label(:snippet), do: "Snippet"
  defp label(:layout), do: "Layout"

  defp cap_diagnostics(diagnostics) do
    diagnostics
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.slice(to_string(&1), 0, @max_message_length))
    |> Enum.take(@max_diagnostics)
  end
end
