defmodule AllbertAssist.Actions.Intent.ReqLLMAnswererTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Intent.DirectAnswer.Policy
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

  test "DirectAnswer exposes its current catalog as pinned version 1" do
    assert Policy.version() == 1
    assert Policy.rule_specs(1) == Policy.rule_specs()
    assert_raise ArgumentError, fn -> Policy.rule_specs(2) end
  end

  test "the actual text provider call preserves system, Memory-data, and operator provenance" do
    operator_request =
      "Acknowledge this supplied statement: maintenance starts 2026-08-15, is staging-only, and uses opaque marker cobalt-17."

    assert {:ok, result} =
             ReqLLMAnswerer.answer(operator_request, %{
               model_profile: profile(),
               active_memory: [
                 %{summary: "Preference", chunk_id: "chunk-1", body: "memory-body-sentinel"}
               ],
               image_inputs: [],
               model_max_retries: 0
             })

    assert result.message == "A useful captured answer."

    assert_receive {:req_llm_generate_text, %{provider: :openai, id: "qwen2.5:7b"},
                    %ReqLLM.Context{} = prompt, opts}

    assert Enum.map(prompt.messages, & &1.role) == [:system, :user, :user]
    refute message_text(hd(prompt.messages)) =~ operator_request
    refute message_text(hd(prompt.messages)) =~ "memory-body-sentinel"
    assert message_text(Enum.at(prompt.messages, 1)) =~ "memory-body-sentinel"
    assert message_text(List.last(prompt.messages)) == operator_request
    assert hd(prompt.messages).metadata.allbert_prompt.rule_ids == Policy.rule_ids()
    assert List.last(prompt.messages).metadata.allbert_prompt.rule_ids == Policy.rule_ids()
    assert opts[:temperature] == 0.0
    assert opts[:max_tokens] == 1024
    assert opts[:receive_timeout] == 60_000
    assert opts[:max_retries] == 0
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

  test "direct-answer sampling stays deterministic after an explicit profile override" do
    overridden =
      profile()
      |> Map.put(:name, "operator_override")
      |> Map.put(:temperature, 0.9)

    assert {:ok, _result} =
             ReqLLMAnswerer.answer("state the supplied fact", %{
               model_profile: overridden,
               active_memory: [],
               image_inputs: []
             })

    assert_receive {:req_llm_generate_text, _spec, _prompt, opts}
    assert opts[:temperature] == 0.0
  end

  test "Objective worker context caps one provider call inside the frozen plan budget" do
    assert {:ok, _result} =
             ReqLLMAnswerer.answer("bounded worker answer", %{
               model_profile: profile(),
               active_memory: [],
               image_inputs: [],
               model_max_output_tokens: 512,
               model_timeout_ms: 2_000
             })

    assert_receive {:req_llm_generate_text, _spec, _prompt, opts}
    assert opts[:max_tokens] == 512
    assert opts[:receive_timeout] == 2_000
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
      name: "direct_answer_local",
      provider_type: "local",
      model: "qwen2.5:7b",
      temperature: 0.0,
      max_tokens: 1024,
      timeout_ms: 60_000
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
