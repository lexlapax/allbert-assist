defmodule AllbertAssist.Workflows.Loader do
  @moduledoc """
  Bounded loader for inert workflow YAML files under Allbert Home.
  """

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Workflows.SchemaError

  @workflow_id ~r/^[a-z0-9][a-z0-9_-]*$/

  @spec workflows_dir() :: String.t()
  def workflows_dir, do: Path.join(Paths.home(), "workflows")

  @spec list_workflows() :: {:ok, [map()], [SchemaError.t()]} | {:error, SchemaError.t()}
  def list_workflows do
    dir = workflows_dir()

    cond do
      not File.dir?(dir) ->
        {:ok, [], [error("/", :no_workflows_dir, workflow_id: nil)]}

      true ->
        {:ok, dir |> Path.join("*.yaml") |> Path.wildcard() |> Enum.map(&file_summary/1), []}
    end
  end

  @spec load(String.t()) :: {:ok, map()} | {:error, SchemaError.t()}
  def load(workflow_id) do
    with {:ok, workflow_id} <- validate_workflow_id(workflow_id),
         {:ok, content} <- read_file(workflow_id),
         :ok <- reject_yaml_features(content, workflow_id),
         {:ok, parsed} <- parse_yaml(content, workflow_id),
         :ok <- validate_filename_id(parsed, workflow_id) do
      {:ok, parsed}
    end
  end

  @spec workflow_path(String.t()) :: {:ok, String.t()} | {:error, SchemaError.t()}
  def workflow_path(workflow_id) do
    with {:ok, workflow_id} <- validate_workflow_id(workflow_id) do
      {:ok, Path.join(workflows_dir(), workflow_id <> ".yaml")}
    end
  end

  @spec exists?(String.t()) :: boolean()
  def exists?(workflow_id) do
    case workflow_path(workflow_id) do
      {:ok, path} -> File.regular?(path)
      {:error, _error} -> false
    end
  end

  @spec validate_workflow_id(term()) :: {:ok, String.t()} | {:error, SchemaError.t()}
  def validate_workflow_id(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(@workflow_id, value) do
      {:ok, value}
    else
      {:error, error("/id", :invalid_id_pattern, got: value, workflow_id: value)}
    end
  end

  def validate_workflow_id(value),
    do: {:error, error("/id", :invalid_id_pattern, got: value, workflow_id: nil)}

  defp file_summary(path) do
    stat = File.stat!(path)
    id = path |> Path.basename(".yaml")

    %{
      id: id,
      path: path,
      size: stat.size,
      mtime: stat.mtime
    }
  end

  defp read_file(workflow_id) do
    with {:ok, path} <- workflow_path(workflow_id) do
      case File.stat(path) do
        {:ok, %{size: size}} ->
          max = max_yaml_bytes()

          cond do
            size > max ->
              {:error,
               error("/", :cap_exceeded,
                 expected: "<= #{max} bytes",
                 got: "#{size} bytes",
                 workflow_id: workflow_id
               )}

            true ->
              case File.read(path) do
                {:ok, content} -> {:ok, content}
                {:error, reason} -> {:error, error("/", :workflow_not_found, got: reason)}
              end
          end

        {:error, :enoent} ->
          {:error, error("/", :workflow_not_found, workflow_id: workflow_id)}

        {:error, reason} ->
          {:error, error("/", :workflow_not_found, got: reason, workflow_id: workflow_id)}
      end
    end
  end

  defp parse_yaml(content, workflow_id) do
    case YamlElixir.read_from_string(content) do
      {:ok, %{} = parsed} ->
        {:ok, parsed}

      {:ok, _other} ->
        {:error, error("/", :type_mismatch, expected: "object", workflow_id: workflow_id)}

      {:error, reason} ->
        {:error,
         error("/", :invalid_yaml,
           got: inspect(reason),
           workflow_id: workflow_id,
           message: "invalid YAML at /"
         )}
    end
  end

  defp reject_yaml_features(content, workflow_id) do
    cond do
      Regex.match?(~r/(^|\s)&[A-Za-z0-9_-]+/, content) ->
        {:error, error("/", :invalid_yaml_feature, got: "anchor", workflow_id: workflow_id)}

      Regex.match?(~r/(^|\s)\*[A-Za-z0-9_-]+/, content) ->
        {:error, error("/", :invalid_yaml_feature, got: "alias", workflow_id: workflow_id)}

      Regex.match?(~r/(^|\n)\s*<<:/, content) ->
        {:error, error("/", :invalid_yaml_feature, got: "merge_key", workflow_id: workflow_id)}

      true ->
        :ok
    end
  end

  defp validate_filename_id(%{"id" => id}, workflow_id) when id == workflow_id, do: :ok

  defp validate_filename_id(%{"id" => id}, workflow_id) do
    {:error,
     error(
       "/id",
       :invalid_id_pattern,
       expected: workflow_id,
       got: id,
       workflow_id: workflow_id
     )}
  end

  defp validate_filename_id(_parsed, workflow_id),
    do: {:error, error("/id", :missing_required, workflow_id: workflow_id)}

  defp max_yaml_bytes do
    case Settings.get("workflows.max_yaml_bytes_per_file") do
      {:ok, bytes} when is_integer(bytes) -> bytes
      _other -> 262_144
    end
  end

  defp error(pointer, reason, attrs) do
    attrs
    |> Keyword.put(:pointer, pointer)
    |> Keyword.put(:reason, reason)
    |> SchemaError.new()
  end
end
