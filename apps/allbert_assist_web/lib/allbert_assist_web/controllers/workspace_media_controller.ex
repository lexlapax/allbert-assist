defmodule AllbertAssistWeb.WorkspaceMediaController do
  @moduledoc false

  use AllbertAssistWeb, :controller

  alias AllbertAssist.Conversations
  alias AllbertAssist.Maps
  alias AllbertAssist.Runtime.Paths, as: RuntimePaths

  @local_user_id "local"

  def show(conn, %{"message_id" => message_id, "index" => index}) do
    with {:ok, index} <- parse_index(index),
         {:ok, message} <- Conversations.get_message(@local_user_id, message_id),
         {:ok, output} <- media_output(message, index),
         {:ok, local_path} <- local_path(output),
         {:ok, safe_path} <- safe_media_path(local_path),
         {:ok, _stat} <- File.stat(safe_path),
         {:ok, mime_type} <- mime_type(output, safe_path) do
      conn
      |> put_resp_content_type(mime_type)
      |> send_file(200, safe_path)
    else
      _error -> send_resp(conn, 404, "Not Found")
    end
  end

  defp parse_index(index) when is_binary(index) do
    case Integer.parse(index) do
      {value, ""} when value >= 0 -> {:ok, value}
      _other -> {:error, :invalid_index}
    end
  end

  defp parse_index(_index), do: {:error, :invalid_index}

  defp media_output(message, index) do
    outputs =
      message
      |> field(:metadata, %{})
      |> field(:media_outputs, [])

    case Enum.at(List.wrap(outputs), index) do
      output when is_map(output) -> {:ok, output}
      _other -> {:error, :media_output_not_found}
    end
  end

  defp local_path(output) do
    case field(output, :local_path) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _other -> {:error, :missing_local_path}
    end
  end

  defp safe_media_path(path) do
    safe_path = Path.expand(path)
    home = RuntimePaths.ensure_home!() |> Path.expand()

    if under_root?(safe_path, home) and supported_extension?(safe_path) do
      {:ok, safe_path}
    else
      {:error, :unsafe_media_path}
    end
  end

  defp under_root?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp supported_extension?(path) do
    path
    |> Path.extname()
    |> String.downcase()
    |> Kernel.in(~w[.png .jpg .jpeg .webp .wav .mp3 .m4a .ogg .webm])
  end

  defp mime_type(output, path) do
    kind = field(output, :kind)
    mime_type = field(output, :mime_type)

    cond do
      supported_mime_type?(kind, mime_type) ->
        {:ok, mime_type}

      kind in [:image, "image"] ->
        {:ok, image_mime_type(path)}

      kind in [:audio, "audio"] ->
        {:ok, audio_mime_type(path)}

      true ->
        {:error, :unsupported_media_kind}
    end
  end

  defp supported_mime_type?(kind, mime_type)
       when kind in [:image, "image"] and is_binary(mime_type),
       do: String.starts_with?(mime_type, "image/")

  defp supported_mime_type?(kind, mime_type)
       when kind in [:audio, "audio"] and is_binary(mime_type),
       do: String.starts_with?(mime_type, "audio/")

  defp supported_mime_type?(_kind, _mime_type), do: false

  defp image_mime_type(path) do
    case path |> Path.extname() |> String.downcase() do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".webp" -> "image/webp"
      _extension -> "image/png"
    end
  end

  defp audio_mime_type(path) do
    case path |> Path.extname() |> String.downcase() do
      ".mp3" -> "audio/mpeg"
      ".m4a" -> "audio/mp4"
      ".ogg" -> "audio/ogg"
      ".webm" -> "audio/webm"
      _extension -> "audio/wav"
    end
  end

  defp field(map, key, default \\ nil), do: Maps.field(map, key, default)
end
