defmodule AllbertAssistWeb.WorkspaceMediaControllerTest do
  use AllbertAssistWeb.ConnCase, async: false

  alias AllbertAssist.Conversations
  alias AllbertAssist.Paths

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADElEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
       )

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-workspace-media-controller-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: home)

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "serves generated media outputs stored on a local conversation message", %{
    conn: conn,
    home: home
  } do
    image_path = Path.join([home, "tmp", "generated-images", "fixture", "image.png"])
    File.mkdir_p!(Path.dirname(image_path))
    File.write!(image_path, @png)

    assert {:ok, thread} = Conversations.create_general_thread("local", "media output")

    assert {:ok, message} =
             Conversations.append_assistant_message(thread, "Image generated.", %{
               metadata: %{
                 media_outputs: [
                   %{
                     kind: :image,
                     local_path: image_path,
                     mime_type: "image/png",
                     source_action: "generate_image"
                   }
                 ]
               }
             })

    conn = get(conn, ~p"/workspace/media/#{message.id}/0")

    assert response(conn, 200) == @png
    assert get_resp_header(conn, "content-type") == ["image/png; charset=utf-8"]
  end

  test "rejects media outputs outside Allbert Home", %{conn: conn} do
    outside_path =
      Path.join(
        System.tmp_dir!(),
        "allbert-workspace-media-outside-#{System.unique_integer([:positive])}.png"
      )

    File.write!(outside_path, @png)
    on_exit(fn -> File.rm(outside_path) end)

    assert {:ok, thread} = Conversations.create_general_thread("local", "outside media")

    assert {:ok, message} =
             Conversations.append_assistant_message(thread, "Image generated.", %{
               metadata: %{
                 media_outputs: [
                   %{
                     kind: :image,
                     local_path: outside_path,
                     mime_type: "image/png",
                     source_action: "generate_image"
                   }
                 ]
               }
             })

    conn = get(conn, ~p"/workspace/media/#{message.id}/0")

    assert response(conn, 404) == "Not Found"
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
