defmodule AllbertAssist.Actions.Intent.ReqLLMAnswererTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Intent.DirectAnswer.ReqLLMAnswerer
  alias ReqLLM.Context
  alias ReqLLM.Response

  defmodule CaptureClient do
    def generate_text(spec, prompt, opts) do
      config = Application.fetch_env!(:allbert_assist, ReqLLMAnswerer)
      send(Keyword.fetch!(config, :test_pid), {:req_llm_generate_text, spec, prompt, opts})

      {:ok,
       %Response{
         id: "capture-response",
         model: "capture-model",
         context: prompt,
         message: Context.assistant("A useful captured answer."),
         usage: %{input_tokens: 10, output_tokens: 5}
       }}
    end
  end

  setup do
    original = Application.get_env(:allbert_assist, ReqLLMAnswerer)

    Application.put_env(:allbert_assist, ReqLLMAnswerer,
      req_llm_client: CaptureClient,
      test_pid: self()
    )

    on_exit(fn -> restore(original) end)
    :ok
  end

  test "the actual text provider call preserves system, Memory-data, and operator provenance" do
    assert {:ok, result} =
             ReqLLMAnswerer.answer("operator-request-sentinel", %{
               model_profile: profile(),
               active_memory: [
                 %{summary: "Preference", chunk_id: "chunk-1", body: "memory-body-sentinel"}
               ],
               image_inputs: []
             })

    assert result.message == "A useful captured answer."

    assert_receive {:req_llm_generate_text, %{provider: :openai, id: "llama3.2:3b"},
                    %ReqLLM.Context{} = prompt, opts}

    assert Enum.map(prompt.messages, & &1.role) == [:system, :user, :user]
    refute message_text(hd(prompt.messages)) =~ "operator-request-sentinel"
    refute message_text(hd(prompt.messages)) =~ "memory-body-sentinel"
    assert message_text(Enum.at(prompt.messages, 1)) =~ "memory-body-sentinel"
    assert message_text(List.last(prompt.messages)) == "operator-request-sentinel"
    assert opts[:temperature] == 0.2
  end

  test "the actual vision provider call attaches the image only to the final user turn" do
    root =
      Path.join(System.tmp_dir!(), "allbert-prompt-image-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    path = Path.join(root, "pixel.png")
    File.write!(path, <<137, 80, 78, 71>>)
    on_exit(fn -> File.rm_rf!(root) end)

    image_input = %{
      path: path,
      mime_type: "image/png",
      resource_uri: "image://capture/pixel",
      content_sha256: String.duplicate("a", 64)
    }

    assert {:ok, result} =
             ReqLLMAnswerer.answer("vision-operator-sentinel", %{
               model_profile: profile(),
               active_memory: [],
               image_inputs: [image_input]
             })

    assert result.message == "A useful captured answer."

    assert_receive {:req_llm_generate_text, _spec, %ReqLLM.Context{} = prompt, _opts}
    assert Enum.map(prompt.messages, & &1.role) == [:system, :user]
    final = List.last(prompt.messages)
    assert Enum.map(final.content, & &1.type) == [:text, :image]
    assert hd(final.content).text == "vision-operator-sentinel"
    refute message_text(hd(prompt.messages)) =~ "vision-operator-sentinel"
    assert final.metadata.allbert_media == [Map.drop(image_input, [:path])]
  end

  test "operator prompt truncation remains valid UTF-8 and inside the byte ceiling" do
    assert {:ok, prompt} =
             ReqLLMAnswerer.prompt_input(String.duplicate("🫡", 2_000), %{
               active_memory: [],
               image_inputs: []
             })

    operator_text = prompt.messages |> List.last() |> message_text()

    assert String.valid?(operator_text)
    assert byte_size(operator_text) <= 4_000
    assert String.ends_with?(operator_text, "...[truncated]")
  end

  defp profile do
    %{
      name: "local",
      provider_type: "local",
      model: "llama3.2:3b",
      temperature: 0.2,
      max_tokens: 512,
      timeout_ms: 3_000
    }
  end

  defp message_text(message) do
    message.content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", & &1.text)
  end

  defp restore(nil), do: Application.delete_env(:allbert_assist, ReqLLMAnswerer)
  defp restore(value), do: Application.put_env(:allbert_assist, ReqLLMAnswerer, value)
end
