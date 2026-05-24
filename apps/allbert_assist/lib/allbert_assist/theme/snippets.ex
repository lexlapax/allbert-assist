defmodule AllbertAssist.Theme.Snippets do
  @moduledoc """
  v0.35 opt-in CSS snippet loading and sanitization.
  """

  alias AllbertAssist.Runtime.Paths
  alias AllbertAssist.Settings

  @max_diagnostics 8
  @max_message_length 180
  @safe_basename ~r/^[A-Za-z0-9_.-]+$/

  @type item :: %{
          basename: String.t() | nil,
          css: String.t(),
          diagnostics: [String.t()],
          fingerprint: String.t() | nil,
          mtime: integer() | nil,
          status: atom()
        }

  @type result :: %{
          css: String.t(),
          diagnostics: [String.t()],
          enabled?: boolean(),
          items: [item()],
          status: atom()
        }

  @spec selected() :: result()
  def selected do
    enabled? = setting("workspace.theme.snippets_enabled", false)
    names = setting("workspace.theme.enabled_snippets", [])

    if enabled? do
      items = Enum.map(names, &load/1)
      diagnostics = items |> Enum.flat_map(& &1.diagnostics) |> cap_diagnostics()

      %{
        css: render_items(items),
        diagnostics: diagnostics,
        enabled?: true,
        items: Enum.map(items, &Map.drop(&1, [:css, :diagnostics])),
        status: snippets_state(items)
      }
    else
      %{css: "", diagnostics: [], enabled?: false, items: [], status: :disabled}
    end
  end

  @spec user_css() :: String.t()
  def user_css, do: selected().css

  @spec single_css(String.t()) :: item()
  def single_css(name) do
    selected_names = setting("workspace.theme.enabled_snippets", [])

    cond do
      not setting("workspace.theme.snippets_enabled", false) ->
        item(nil, "", :disabled)

      not enabled_name?(name, selected_names) ->
        item(nil, "", :not_enabled, ["Snippet #{safe_display(name)} is not enabled."])

      true ->
        load(name)
    end
  end

  @spec sanitize(String.t()) :: %{css: String.t(), diagnostics: [String.t()], status: atom()}
  def sanitize(css) when is_binary(css) do
    {css, diagnostics} =
      [
        {~r/@import\s+[^;]+;?/i, "Removed @import rule."},
        {~r/@font-face\s*\{[^}]*\}/ims, "Removed @font-face rule."},
        {~r/\bsrc\s*:\s*[^;]+;?/i, "Removed remote source declaration."},
        {~r/url\([^)]*\)/i, "Removed url() value."},
        {~r/image-set\([^)]*\)/i, "Removed image-set() value."}
      ]
      |> Enum.reduce({css, []}, fn {pattern, diagnostic}, {current, diagnostics} ->
        if Regex.match?(pattern, current) do
          {Regex.replace(pattern, current, "none"), diagnostics ++ [diagnostic]}
        else
          {current, diagnostics}
        end
      end)

    css = strip_empty_rules(css)
    diagnostics = cap_diagnostics(diagnostics)

    %{
      css: css,
      diagnostics: diagnostics,
      status: sanitize_status(css, diagnostics)
    }
  end

  def sanitize(_css),
    do: %{css: "", diagnostics: ["Snippet ignored: CSS must be text."], status: :empty}

  @spec css_basename(term()) :: String.t() | {:error, String.t()}
  def css_basename(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        {:error, "empty snippet name"}

      unsafe_path?(value) ->
        {:error, "unsafe snippet name"}

      not Regex.match?(@safe_basename, value) ->
        {:error, "snippet name has unsupported characters"}

      Path.extname(value) not in ["", ".css"] ->
        {:error, "snippet file must be .css"}

      String.ends_with?(value, ".css") ->
        value

      true ->
        value <> ".css"
    end
  end

  def css_basename(_value), do: {:error, "snippet name must be text"}

  defp load(name) do
    with basename when is_binary(basename) <- css_basename(name),
         {:ok, path} <- snippet_path(basename),
         {:ok, stat} <- file_stat(path, basename),
         {:ok, contents} <- File.read(path) do
      sanitized = sanitize(contents)

      item(basename, sanitized.css, sanitized.status, sanitized.diagnostics, %{
        fingerprint: fingerprint(path),
        mtime: stat.mtime
      })
    else
      {:error, reason} ->
        item(nil, "", :invalid_selection, ["Snippet selection ignored: #{reason}."])

      {:missing, basename} ->
        item(basename, "", :missing, ["Snippet file #{basename} is missing."])

      {:invalid, basename, reason} ->
        item(basename, "", :invalid, ["Snippet file #{basename} ignored: #{reason}."])
    end
  end

  defp snippet_path(basename) do
    root = Path.expand(Paths.theme_snippets_root())
    path = Path.expand(Path.join(root, basename))

    if String.starts_with?(path, root <> "/") do
      {:ok, path}
    else
      {:error, "unsafe snippet name"}
    end
  end

  defp file_stat(path, basename) do
    cond do
      not File.exists?(path) ->
        {:missing, basename}

      match?({:ok, %{type: :symlink}}, File.lstat(path)) ->
        {:invalid, basename, "symlinks are not allowed"}

      File.dir?(path) ->
        {:invalid, basename, "is a directory"}

      true ->
        case File.stat(path, time: :posix) do
          {:ok, stat} -> {:ok, stat}
          {:error, reason} -> {:invalid, basename, inspect(reason)}
        end
    end
  end

  defp enabled_name?(name, selected_names) do
    case css_basename(name) do
      basename when is_binary(basename) ->
        Enum.any?(selected_names, &(css_basename(&1) == basename))

      _other ->
        false
    end
  end

  defp render_items(items) do
    items
    |> Enum.filter(&(&1.css != ""))
    |> Enum.map_join("\n", fn item -> "/* Allbert snippet: #{item.basename} */\n#{item.css}" end)
  end

  defp snippets_state([]), do: :empty

  defp snippets_state(items) do
    cond do
      Enum.any?(items, &(&1.status in [:present, :sanitized])) -> :present
      Enum.any?(items, &(&1.status == :empty)) -> :empty
      true -> :unavailable
    end
  end

  defp sanitize_status(css, []), do: if(String.trim(css) == "", do: :empty, else: :present)

  defp sanitize_status(css, _diagnostics),
    do: if(String.trim(css) == "", do: :empty, else: :sanitized)

  defp strip_empty_rules(css) do
    css
    |> String.replace(~r/^[[:space:]]*none[[:space:]]*$/m, "")
    |> String.trim()
    |> then(fn
      "" -> ""
      value -> value <> "\n"
    end)
  end

  defp item(basename, css, status, diagnostics \\ [], attrs \\ %{}) do
    Map.merge(
      %{
        basename: basename,
        css: css,
        diagnostics: cap_diagnostics(diagnostics),
        fingerprint: nil,
        mtime: nil,
        status: status
      },
      attrs
    )
  end

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

  defp safe_display(name) when is_binary(name) do
    name
    |> String.replace(~r/[^A-Za-z0-9_.-]/, "?")
    |> String.slice(0, 80)
  end

  defp safe_display(_name), do: "<invalid>"

  defp cap_diagnostics(diagnostics) do
    diagnostics
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.slice(to_string(&1), 0, @max_message_length))
    |> Enum.take(@max_diagnostics)
  end
end
