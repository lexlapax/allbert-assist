defmodule AllbertAssist.PublicProtocol.OpenAIMappingTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.PublicProtocol.OpenAI.Mapping
  alias AllbertAssist.Settings

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    root = temp_root("openai-mapping")

    File.rm_rf!(root)
    Application.put_env(:allbert_assist, Settings, root: root)

    assert {:ok, _setting} =
             Settings.put("openai_api.models_enabled", ["local"], %{audit?: false})

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "flattens string and text-part messages into one runtime turn" do
    request = %{
      "model" => "local",
      "user" => "operator",
      "messages" => [
        %{"role" => "developer", "content" => "Stay concise."},
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => "First line."},
            %{"type" => "text", "text" => "Second line."}
          ]
        }
      ]
    }

    assert {:ok, chat} = Mapping.parse_chat_request(request, %{client_id: "local"})
    assert chat.model == "local"
    assert chat.user_id == "operator"
    assert chat.stream? == false
    assert chat.text == "developer: Stay concise.\nuser: First line.\nSecond line."

    runtime_request = Mapping.runtime_request(chat, %{client_id: "local"})
    assert runtime_request.channel == :openai_api
    assert runtime_request.user_id == "operator"
    assert get_in(runtime_request.metadata, [:public_protocol, :surface]) == "openai_api"
    assert get_in(runtime_request.metadata, [:openai_api, :model]) == "local"
  end

  test "rejects client tool selection and non-text content" do
    base = %{
      "model" => "local",
      "messages" => [%{"role" => "user", "content" => "hello"}]
    }

    assert {:error, tools_error} =
             Mapping.parse_chat_request(Map.put(base, "tools", []), %{client_id: "local"})

    assert tools_error.param == "tools"
    assert tools_error.code == "unsupported_parameter"

    image_request = %{
      "model" => "local",
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "image_url", "image_url" => %{"url" => "https://example.com/a.png"}}
          ]
        }
      ]
    }

    assert {:error, image_error} =
             Mapping.parse_chat_request(image_request, %{client_id: "local"})

    assert image_error.param == "messages"
    assert image_error.code == "unsupported_content_part"
  end

  test "rejects assistant-history tool metadata before runtime mapping" do
    base = %{
      "model" => "local",
      "messages" => [%{"role" => "assistant", "content" => "hello"}]
    }

    assert {:error, tool_calls_error} =
             Mapping.parse_chat_request(
               put_in(base, ["messages", Access.at(0), "tool_calls"], []),
               %{client_id: "local"}
             )

    assert tool_calls_error.param == "messages"
    assert tool_calls_error.code == "unsupported_parameter"

    assert {:error, function_call_error} =
             Mapping.parse_chat_request(
               put_in(base, ["messages", Access.at(0), "function_call"], %{}),
               %{client_id: "local"}
             )

    assert function_call_error.param == "messages"
    assert function_call_error.code == "unsupported_parameter"
  end

  test "rejects model aliases not enabled through Settings Central" do
    request = %{
      "model" => "missing",
      "messages" => [%{"role" => "user", "content" => "hello"}]
    }

    assert {:error, error} = Mapping.parse_chat_request(request, %{client_id: "local"})
    assert error.param == "model"
    assert error.code == "model_not_enabled"
  end

  test "models response exposes only Settings-enabled aliases" do
    assert {:ok, body} = Mapping.models_response()

    assert %{
             "object" => "list",
             "data" => [%{"id" => "local", "object" => "model", "owned_by" => "allbert"}]
           } = body
  end

  defp temp_root(prefix) do
    Path.join(
      System.tmp_dir!(),
      "allbert-#{prefix}-#{System.pid()}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
