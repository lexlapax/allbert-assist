defmodule AllbertAssist.Templates.Renderer do
  @moduledoc """
  Deterministic renderer for reviewed v0.38 template files.

  Rendering is simple placeholder substitution against already-validated
  parameter data. It does not evaluate user-supplied code or template source.
  """

  alias AllbertAssist.Templates.Parameters

  @placeholder ~r/\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/
  @max_file_bytes 128 * 1024

  @type rendered_file :: %{
          required(:path) => String.t(),
          required(:content) => String.t(),
          required(:bytes) => non_neg_integer()
        }

  @doc "Render a pattern module with raw params into an ordered file list."
  @spec render(module(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def render(pattern, params, opts \\ [])

  def render(pattern, params, opts) when is_atom(pattern) and is_map(params) do
    with :ok <- validate_pattern(pattern),
         {:ok, normalized} <- normalize_params(pattern, params),
         {:ok, files} <- render_files(pattern, normalized, opts) do
      {:ok,
       %{
         pattern_id: pattern.id(),
         pattern: pattern,
         params: normalized,
         target_shapes: pattern.target_shapes(),
         live_integration?: pattern.live_integration?(),
         files: files
       }}
    end
  end

  def render(_pattern, _params, _opts), do: {:error, :invalid_render_input}

  @doc "Return true when a relative output path stays inside a target root."
  @spec safe_relative_path?(String.t()) :: boolean()
  def safe_relative_path?(path) when is_binary(path) do
    case safe_relative_path(path) do
      {:ok, _path} -> true
      {:error, _reason} -> false
    end
  end

  def safe_relative_path?(_path), do: false

  @doc "Validate and normalize a relative output path."
  @spec safe_relative_path(String.t()) :: {:ok, String.t()} | {:error, term()}
  def safe_relative_path(path) when is_binary(path) do
    normalized = Path.expand(path, "/template-target")
    root = Path.expand("/template-target")

    cond do
      String.trim(path) == "" ->
        {:error, :empty_template_path}

      Path.type(path) == :absolute ->
        {:error, {:absolute_template_path, path}}

      normalized == root or not String.starts_with?(normalized, root <> "/") ->
        {:error, {:unsafe_template_path, path}}

      true ->
        {:ok, Path.relative_to(normalized, root)}
    end
  end

  def safe_relative_path(_path), do: {:error, :invalid_template_path}

  defp validate_pattern(pattern) do
    required = [
      :id,
      :label,
      :description,
      :parameter_schema,
      :files,
      :target_shapes,
      :live_integration?
    ]

    if Code.ensure_loaded?(pattern) and Enum.all?(required, &function_exported?(pattern, &1, 0)) do
      :ok
    else
      {:error, {:invalid_template_pattern, pattern}}
    end
  end

  defp normalize_params(pattern, params) do
    with {:ok, validated} <- Parameters.validate(pattern.parameter_schema(), params),
         {:ok, common} <- Parameters.derive_common(validated) do
      if function_exported?(pattern, :normalize_params, 1) do
        pattern.normalize_params(common)
      else
        {:ok, common}
      end
    end
  end

  defp render_files(pattern, params, opts) do
    pattern.files()
    |> Enum.reduce_while({:ok, []}, fn spec, {:ok, acc} ->
      case render_file(pattern, spec, params, opts) do
        {:ok, file} -> {:cont, {:ok, [file | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp render_file(pattern, spec, params, opts) when is_map(spec) do
    with {:ok, target} <- render_target(spec, params),
         {:ok, template} <- template_content(pattern, spec, opts),
         {:ok, content} <- substitute(template, params),
         :ok <- validate_size(target, content) do
      {:ok, %{path: target, content: content, bytes: byte_size(content)}}
    end
  end

  defp render_file(_pattern, spec, _params, _opts), do: {:error, {:invalid_file_spec, spec}}

  defp render_target(spec, params) do
    with target when is_binary(target) <- value(spec, :target),
         {:ok, rendered} <- substitute(target, params),
         {:ok, safe} <- safe_relative_path(rendered) do
      {:ok, safe}
    else
      nil -> {:error, {:missing_file_target, spec}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp template_content(_pattern, spec, _opts) do
    case value(spec, :content) do
      content when is_binary(content) -> {:ok, content}
      _other -> template_source_content(spec)
    end
  end

  defp template_source_content(spec) do
    with source when is_binary(source) <- value(spec, :source),
         {:ok, source} <- safe_relative_path(source),
         {:ok, content} <- File.read(Path.join(template_root(), source)) do
      {:ok, content}
    else
      nil -> {:error, {:missing_file_content, spec}}
      {:error, reason} -> {:error, {:template_source_read_failed, value(spec, :source), reason}}
    end
  end

  defp substitute(template, params) do
    rendered =
      Regex.replace(@placeholder, template, fn _match, key ->
        case Map.fetch(params, key) do
          {:ok, value} -> to_string(value)
          :error -> "{{#{key}}}"
        end
      end)

    case Regex.scan(@placeholder, rendered) do
      [] ->
        {:ok, rendered}

      unresolved ->
        {:error, {:unresolved_template_placeholders, Enum.map(unresolved, &List.last/1)}}
    end
  end

  defp validate_size(path, content) do
    if byte_size(content) <= @max_file_bytes do
      :ok
    else
      {:error, {:rendered_file_too_large, path, @max_file_bytes}}
    end
  end

  defp template_root do
    :allbert_assist
    |> :code.priv_dir()
    |> Path.join("templates/v0_38")
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
