defmodule AllbertAssist.Theme.Tokens do
  @moduledoc """
  v0.35 token-theme parser and renderer.

  Token themes are local Allbert Home YAML files. They can only reassign the
  pinned presentational `--allbert-*` custom properties for `#workspace-shell`.
  """

  alias AllbertAssist.Runtime.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.YamlCodec

  @max_diagnostics 8
  @max_message_length 180
  @safe_basename ~r/^[A-Za-z0-9_.-]+$/

  @color_tokens ~w[
    allbert-surface-0
    allbert-surface-1
    allbert-surface-2
    allbert-text-strong
    allbert-text-soft
    allbert-line
    allbert-accent
    allbert-accent-contrast
    allbert-accent-soft
    allbert-warn
    allbert-warn-soft
    allbert-danger
    allbert-success
  ]

  @token_specs %{
    "allbert-font-family" => :font_family,
    "allbert-font-scale" => {:number, 0.85, 1.2},
    "allbert-density" => {:number, 0.85, 1.2},
    "allbert-radius" => :length,
    "allbert-border-width" => :length,
    "allbert-motion-scale" => {:number, 0.0, 1.5}
  }

  @token_specs Enum.reduce(@color_tokens, @token_specs, &Map.put(&2, &1, :color))

  @type load_result :: %{
          basename: String.t() | nil,
          declarations: map(),
          diagnostics: [String.t()],
          fingerprint: String.t() | nil,
          mtime: integer() | nil,
          status: atom()
        }

  @spec allow_list() :: [String.t()]
  def allow_list do
    @token_specs
    |> Map.keys()
    |> Enum.map(&"--#{&1}")
    |> Enum.sort()
  end

  @spec selected() :: load_result()
  def selected do
    active = setting("workspace.theme.active", nil)

    case theme_basename(active) do
      nil ->
        result(nil, :not_selected)

      {:error, reason} ->
        result(nil, :invalid_selection, ["Token theme selection ignored: #{reason}."])

      basename ->
        load(Path.join(Paths.themes_root(), basename), basename)
    end
  end

  @spec user_css() :: String.t()
  def user_css do
    selected()
    |> Map.fetch!(:declarations)
    |> render()
  end

  @spec render(map()) :: String.t()
  def render(declarations) when is_map(declarations) and map_size(declarations) == 0 do
    "/* Allbert token theme: no active token overrides. */\n"
  end

  def render(declarations) when is_map(declarations) do
    body =
      declarations
      |> Enum.sort_by(fn {name, _value} -> name end)
      |> Enum.map_join("\n", fn {name, value} -> "  #{name}: #{value};" end)

    "#workspace-shell {\n#{body}\n}\n"
  end

  def render(_declarations), do: "/* Allbert token theme: invalid declarations. */\n"

  @spec theme_basename(term()) :: String.t() | nil | {:error, String.t()}
  def theme_basename(value) when value in [nil, ""], do: nil

  def theme_basename(value) when is_binary(value) do
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

  def theme_basename(_value), do: {:error, "theme name must be text"}

  defp load(path, basename) do
    cond do
      not File.exists?(path) ->
        result(basename, :missing, ["Token theme file #{basename} is missing."])

      File.dir?(path) ->
        result(basename, :invalid, ["Token theme file #{basename} is a directory."])

      true ->
        parse_file(path, basename)
    end
  end

  defp parse_file(path, basename) do
    case YamlCodec.read_file(path) do
      {:ok, %{} = yaml} ->
        yaml
        |> Map.get("tokens", %{})
        |> validate_tokens()
        |> then(fn {declarations, diagnostics} ->
          status = token_status(declarations, diagnostics)

          result(basename, status, diagnostics, %{
            declarations: declarations,
            fingerprint: fingerprint(path),
            mtime: mtime(path)
          })
        end)

      {:error, reason} ->
        result(basename, :invalid, [
          "Token theme file #{basename} could not be parsed: #{reason_text(reason)}."
        ])
    end
  end

  defp validate_tokens(tokens) when is_map(tokens) do
    tokens
    |> Enum.reduce({%{}, []}, fn {key, value}, {declarations, diagnostics} ->
      key = normalize_key(key)

      case validate_token(key, value) do
        {:ok, css_name, css_value} ->
          {Map.put(declarations, css_name, css_value), diagnostics}

        {:error, reason} ->
          {declarations, diagnostics ++ ["Token #{display_key(key)} ignored: #{reason}."]}
      end
    end)
    |> then(fn {declarations, diagnostics} ->
      {declarations, cap_diagnostics(diagnostics)}
    end)
  end

  defp validate_tokens(_tokens), do: {%{}, ["Token theme ignored: tokens must be a map."]}

  defp validate_token(nil, _value), do: {:error, "name must be text"}

  defp validate_token(key, value) do
    case Map.fetch(@token_specs, key) do
      {:ok, spec} ->
        with {:ok, css_value} <- validate_value(value, spec) do
          {:ok, "--#{key}", css_value}
        end

      :error ->
        {:error, "outside the v0.35 presentational token allow-list"}
    end
  end

  defp validate_value(value, :color) when is_binary(value) do
    value = String.trim(value)

    if safe_css_value?(value) and color_value?(value) do
      {:ok, value}
    else
      {:error, "invalid color value"}
    end
  end

  defp validate_value(value, :font_family) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:error, "font family cannot be empty"}
      not safe_css_value?(value) -> {:error, "invalid font family value"}
      not Regex.match?(~r/^[A-Za-z0-9\s,"'._-]+$/, value) -> {:error, "invalid font family value"}
      true -> {:ok, value}
    end
  end

  defp validate_value(value, :length) when is_binary(value) do
    value = String.trim(value)

    if safe_css_value?(value) and Regex.match?(~r/^(0|[0-9]+(?:\.[0-9]+)?(?:px|rem|em))$/, value) do
      {:ok, value}
    else
      {:error, "invalid length value"}
    end
  end

  defp validate_value(value, {:number, min, max}) when is_number(value) do
    number = value / 1

    if number >= min and number <= max do
      {:ok, number_text(number)}
    else
      {:error, "number outside #{min}..#{max}"}
    end
  end

  defp validate_value(value, {:number, min, max}) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> validate_value(number, {:number, min, max})
      _other -> {:error, "invalid number value"}
    end
  end

  defp validate_value(_value, _spec), do: {:error, "invalid value type"}

  defp color_value?(value) do
    Regex.match?(~r/^#(?:[0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/, value) or
      Regex.match?(~r/^(?:rgb|rgba|hsl|hsla|oklch|lab)\([0-9a-zA-Z\s.,%+\/-]+\)$/, value)
  end

  defp safe_css_value?(value) do
    value != "" and
      not String.contains?(String.downcase(value), ["url(", "image-set(", "@import"]) and
      not Regex.match?(~r/[;{}<>]/, value) and
      not String.contains?(value, ["\n", "\r"])
  end

  defp token_status(declarations, diagnostics) do
    cond do
      map_size(declarations) == 0 and diagnostics != [] -> :invalid
      diagnostics != [] -> :partial
      true -> :present
    end
  end

  defp normalize_key(key) when is_binary(key) do
    key
    |> String.trim()
    |> String.trim_leading("--")
  end

  defp normalize_key(_key), do: nil

  defp display_key(nil), do: "<invalid>"
  defp display_key(key), do: key

  defp result(basename, status, diagnostics \\ [], attrs \\ %{}) do
    Map.merge(
      %{
        basename: basename,
        declarations: %{},
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

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      _other -> nil
    end
  end

  defp number_text(number) do
    number
    |> :erlang.float_to_binary(decimals: 4)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  defp reason_text(reason) do
    reason
    |> inspect()
    |> String.replace(~r/\s+/, " ")
  end

  defp cap_diagnostics(diagnostics) do
    diagnostics
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.slice(to_string(&1), 0, @max_message_length))
    |> Enum.take(@max_diagnostics)
  end
end
