defmodule AllbertAssist.Templates.Scaffold do
  @moduledoc """
  Writes inert developer scaffolds from reviewed v0.38 templates.

  Existing target roots are never overwritten unless `force?: true` is passed.
  The writer only creates or overwrites files declared by the reviewed rendered
  file set and verifies every destination stays under the target root.
  """

  alias AllbertAssist.Templates

  @doc "Render and write a developer scaffold."
  @spec write(String.t() | atom(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def write(pattern_id, params, opts \\ [])

  def write(pattern_id, params, opts) when is_map(params) do
    with {:ok, rendered} <- Templates.render(pattern_id, params),
         {:ok, target_root} <- target_root(rendered.params, opts),
         :ok <- ensure_write_allowed(target_root, rendered, opts),
         {:ok, files} <- write_files(target_root, rendered.files) do
      {:ok,
       %{
         pattern_id: rendered.pattern_id,
         params: rendered.params,
         target_root: target_root,
         files: files,
         live_integration?: rendered.live_integration?,
         target_shapes: rendered.target_shapes
       }}
    end
  end

  def write(_pattern_id, _params, _opts), do: {:error, :invalid_scaffold_input}

  @doc "Return a scaffold preview without writing files."
  @spec preview(String.t() | atom(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def preview(pattern_id, params, opts \\ [])

  def preview(pattern_id, params, opts) when is_map(params) do
    with {:ok, rendered} <- Templates.render(pattern_id, params),
         {:ok, target_root} <- target_root(rendered.params, opts) do
      {:ok,
       %{
         pattern_id: rendered.pattern_id,
         params: rendered.params,
         target_root: target_root,
         existing?: File.exists?(target_root),
         files: preview_files(target_root, rendered.files),
         live_integration?: rendered.live_integration?,
         target_shapes: rendered.target_shapes
       }}
    end
  end

  def preview(_pattern_id, _params, _opts), do: {:error, :invalid_scaffold_input}

  defp target_root(params, opts) do
    target = Keyword.get(opts, :target)
    slug = Map.fetch!(params, "slug")
    raw = target || Path.join(["plugins", slug])

    with :ok <- reject_parent_segments(raw) do
      {:ok, Path.expand(raw, File.cwd!())}
    end
  end

  defp reject_parent_segments(path) when is_binary(path) do
    if ".." in Path.split(path), do: {:error, {:unsafe_target_root, path}}, else: :ok
  end

  defp reject_parent_segments(path), do: {:error, {:unsafe_target_root, path}}

  defp ensure_write_allowed(target_root, rendered, opts) do
    force? = Keyword.get(opts, :force?, false)

    cond do
      not File.exists?(target_root) ->
        :ok

      force? ->
        :ok

      true ->
        {:error, {:target_exists, preview_from_rendered(target_root, rendered)}}
    end
  end

  defp preview_from_rendered(target_root, rendered) do
    %{
      pattern_id: rendered.pattern_id,
      target_root: target_root,
      existing?: true,
      files: preview_files(target_root, rendered.files)
    }
  end

  defp preview_files(target_root, files) do
    Enum.map(files, fn file ->
      destination = destination_path!(target_root, file.path)

      %{
        path: file.path,
        destination: destination,
        bytes: file.bytes,
        status: if(File.exists?(destination), do: :overwrite, else: :create)
      }
    end)
  end

  defp write_files(target_root, files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      destination = destination_path!(target_root, file.path)

      case write_file(destination, file.content) do
        :ok ->
          {:cont,
           {:ok,
            [
              %{path: file.path, destination: destination, bytes: file.bytes}
              | acc
            ]}}

        {:error, reason} ->
          {:halt, {:error, {:write_failed, file.path, reason}}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp destination_path!(target_root, relative_path) do
    destination = Path.expand(relative_path, target_root)
    root = Path.expand(target_root)

    if destination == root or String.starts_with?(destination, root <> "/") do
      destination
    else
      raise ArgumentError, "template destination escapes target root"
    end
  end

  defp write_file(destination, content) do
    with :ok <- File.mkdir_p(Path.dirname(destination)) do
      File.write(destination, content)
    end
  end
end
