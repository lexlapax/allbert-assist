defmodule AllbertAssist.Workspace.BodyStore do
  @moduledoc false

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings.Store, as: SettingsStore
  alias AllbertAssist.Settings.YamlCodec

  @type write_error ::
          {:body_write_failed, {module(), String.t()}}
          | {:settings_write_failed, {term(), term()}}
  @type read_error :: {:settings_parse_failed, String.t() | {:expected_map, term()}}

  @spec canvas_body_path(String.t(), String.t(), String.t()) :: String.t()
  def canvas_body_path(user_id, thread_id, tile_id) do
    Path.join(["workspace", "canvas", safe(user_id), safe(thread_id), "#{safe(tile_id)}.yml"])
  end

  @spec deleted_canvas_body_path(String.t(), DateTime.t()) :: String.t()
  def deleted_canvas_body_path(relative_path, %DateTime{} = timestamp) do
    dirname = Path.dirname(relative_path)
    basename = Path.basename(relative_path, ".yml")
    Path.join(dirname, "#{basename}.deleted.#{stamp(timestamp)}.yml")
  end

  @spec ephemeral_body_path(String.t(), String.t(), String.t()) :: String.t()
  def ephemeral_body_path(user_id, thread_id, surface_id) do
    Path.join([
      "workspace",
      "ephemeral",
      safe(user_id),
      safe(thread_id),
      "#{safe(surface_id)}.yml"
    ])
  end

  @spec write_body(String.t(), map()) :: :ok | {:error, write_error()}
  def write_body(relative_path, body) when is_binary(relative_path) and is_map(body) do
    relative_path
    |> absolute()
    |> SettingsStore.write_atomic(YamlCodec.encode!(stringify(body)))
  rescue
    exception ->
      {:error, {:body_write_failed, {exception.__struct__, Exception.message(exception)}}}
  end

  @spec read_body(String.t() | nil) :: {:ok, map()} | {:error, read_error()}
  def read_body(nil), do: {:ok, %{}}

  def read_body(relative_path) when is_binary(relative_path) do
    case YamlCodec.read_file(absolute(relative_path)) do
      {:ok, %{} = body} -> {:ok, body}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec move(String.t(), String.t()) :: :ok | {:error, term()}
  def move(from_relative, to_relative) do
    from = absolute(from_relative)
    to = absolute(to_relative)
    File.mkdir_p!(Path.dirname(to))

    case File.rename(from, to) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:body_move_failed, reason}}
    end
  end

  @spec delete(String.t()) :: :ok | {:error, {:body_delete_failed, atom()}}
  def delete(relative_path) when is_binary(relative_path) do
    case File.rm(absolute(relative_path)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:body_delete_failed, reason}}
    end
  end

  defp absolute(relative_path), do: Path.join(Paths.home(), relative_path)

  defp stamp(timestamp) do
    timestamp
    |> DateTime.to_iso8601(:basic)
    |> String.replace(["-", ":", "."], "")
  end

  defp safe(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
  end

  defp stringify(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp stringify(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)
  defp stringify(%_struct{} = struct), do: struct |> Map.from_struct() |> stringify()

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
