defmodule AllbertAssist.Theme.Status do
  @moduledoc """
  Read-only accountability status for v0.35 file-backed workspace overrides.

  Settings Central owns the gates and selections; this module inspects the
  corresponding Allbert Home files without storing their contents as settings.
  """

  alias AllbertAssist.Runtime.Paths
  alias AllbertAssist.Settings

  @max_diagnostics 8
  @max_message_length 180
  @safe_basename ~r/^[A-Za-z0-9_.-]+$/

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
    active = setting("workspace.theme.active", nil)

    case theme_basename(active) do
      nil ->
        {%{basename: nil, fingerprint: nil, mtime: nil, status: :not_selected}, []}

      {:error, reason} ->
        {%{basename: nil, fingerprint: nil, mtime: nil, status: :invalid_selection},
         ["Token theme selection ignored: #{reason}."]}

      basename ->
        path = Path.join(Paths.themes_root(), basename)

        file_status(path, basename, :token)
    end
  end

  defp snippets_status do
    enabled? = setting("workspace.theme.snippets_enabled", false)
    names = setting("workspace.theme.enabled_snippets", [])

    if enabled? do
      {items, diagnostics} =
        names
        |> Enum.map(&snippet_item/1)
        |> Enum.unzip()

      {%{enabled?: true, items: items, status: snippets_state(items)},
       cap_diagnostics(diagnostics)}
    else
      {%{enabled?: false, items: [], status: :disabled}, []}
    end
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

  defp snippet_item(name) do
    case css_basename(name) do
      {:error, reason} ->
        {%{basename: nil, fingerprint: nil, mtime: nil, status: :invalid_selection},
         "Snippet selection ignored: #{reason}."}

      basename ->
        path = Path.join(Paths.theme_snippets_root(), basename)
        {status, diagnostics} = file_status(path, basename, :snippet)
        {status, List.first(diagnostics)}
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

  defp snippets_state([]), do: :empty

  defp snippets_state(items) do
    if Enum.any?(items, &(&1.status == :present)), do: :present, else: :unavailable
  end

  defp theme_basename(value) when value in [nil, ""], do: nil

  defp theme_basename(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        nil

      unsafe_path?(value) ->
        {:error, "unsafe theme name"}

      not Regex.match?(@safe_basename, value) ->
        {:error, "theme name has unsupported characters"}

      String.ends_with?(value, ".yaml") ->
        value

      true ->
        value <> ".yaml"
    end
  end

  defp theme_basename(_value), do: {:error, "theme name must be text"}

  defp css_basename(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        {:error, "empty snippet name"}

      unsafe_path?(value) ->
        {:error, "unsafe snippet name"}

      not Regex.match?(@safe_basename, value) ->
        {:error, "snippet name has unsupported characters"}

      String.ends_with?(value, ".css") ->
        value

      true ->
        value <> ".css"
    end
  end

  defp css_basename(_value), do: {:error, "snippet name must be text"}

  defp unsafe_path?(value) do
    String.contains?(value, ["/", "\\"]) or Path.basename(value) != value or value in [".", ".."]
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
