defmodule AllbertAssist.Intent.Router.OptimizerModelGenerationTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Channels.SendChannelMessage
  alias AllbertAssist.Intent.Descriptor
  alias AllbertAssist.Intent.Router.Optimizer
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  defmodule ValidLLM do
    def generate_object(spec, prompt, schema, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:llm_request, spec, prompt, schema, opts})

      {:ok,
       %{
         object: %{
           "label" => "Send a channel message",
           "examples" => [
             "send a slack message to #eng saying release is ready",
             "message the discord channel with the deploy status",
             "send a telegram note to alex"
           ],
           "synonyms" => ["send channel message", "post to channel", "message channel"],
           "required_slots" => ["channel", "target", "body"],
           "optional_slots" => [],
           "negative_phrases" => ["list channels", "show channel status"]
         }
       }}
    end
  end

  defmodule InvalidLLM do
    def generate_object(_spec, _prompt, _schema, opts) do
      send(Keyword.fetch!(opts, :test_pid), :invalid_llm_called)
      {:ok, %{object: %{"label" => "", "examples" => []}}}
    end
  end

  defmodule SecretEchoLLM do
    def generate_object(_spec, _prompt, _schema, opts) do
      send(Keyword.fetch!(opts, :test_pid), :secret_echo_llm_called)

      {:ok,
       %{
         object: %{
           "label" => "Use sk-testsecret to send",
           "examples" => ["send using secret://providers/openai/api_key"],
           "synonyms" => ["send bearer xoxb-testsecret"],
           "required_slots" => ["channel"],
           "optional_slots" => [],
           "negative_phrases" => []
         }
       }}
    end
  end

  defmodule ForbiddenLLM do
    def generate_object(_spec, _prompt, _schema, opts) do
      send(Keyword.fetch!(opts, :test_pid), :unexpected_llm_call)
      {:error, :unexpected_llm_call}
    end
  end

  setup do
    original_home = System.get_env("ALLBERT_HOME")
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-opt-model-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.rm_rf!(home)
    System.put_env("ALLBERT_HOME", home)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)

    on_exit(fn ->
      if original_home,
        do: System.put_env("ALLBERT_HOME", original_home),
        else: System.delete_env("ALLBERT_HOME")

      restore(Paths, original_paths)
      restore(Settings, original_settings)
      File.rm_rf!(home)
    end)

    :ok
  end

  test "model strategy uses local router profile and returns a normalized descriptor" do
    attrs = generate_with(ValidLLM)

    assert_receive {:llm_request, %{provider: :openai, id: "llama3.1:8b"}, prompt, schema, opts}

    assert schema[:label][:required]
    assert opts[:receive_timeout] == 20_000
    assert opts[:openai_structured_output_mode] == :json_schema
    assert prompt =~ "send_channel_message"
    assert prompt =~ "Send an outbound message to a channel"
    refute prompt =~ "http://"
    refute prompt =~ "secret://"
    refute prompt =~ "sk-"

    assert attrs.label == "Send a channel message"
    assert "send channel message" in attrs.synonyms
    assert attrs.required_slots == [:channel, :target, :body]
    assert attrs.vocabulary.negative_phrases == ["list channels", "show channel status"]
    assert attrs.generation.strategy == "model"
    assert attrs.generation.model_profile == "router_local"
    assert attrs.generation.endpoint_kind == "local_endpoint"
    refute inspect(attrs) =~ "http://"

    assert {:ok, descriptor} = Descriptor.normalize(attrs)
    assert descriptor.action_name == "send_channel_message"
  end

  test "remote router profile falls back to heuristic without calling the model" do
    assert {:ok, _setting} =
             Settings.put("intent.router_model_profile", "fast", %{audit?: false})

    attrs = generate_with(ForbiddenLLM)

    refute_received :unexpected_llm_call
    assert attrs.label == "Send channel message"
    assert attrs.generation.strategy == "heuristic"
    assert attrs.generation.fallback_reason == "non_local_model_profile"
  end

  test "disabled local provider falls back to heuristic without calling the model" do
    assert {:ok, _setting} =
             Settings.put("providers.local_ollama.enabled", false, %{audit?: false})

    attrs = generate_with(ForbiddenLLM)

    refute_received :unexpected_llm_call
    assert attrs.label == "Send channel message"
    assert attrs.generation.strategy == "heuristic"
    assert attrs.generation.fallback_reason == "provider_disabled"
  end

  test "invalid model output falls back to the heuristic descriptor" do
    attrs = generate_with(InvalidLLM)

    assert_received :invalid_llm_called
    assert attrs.label == "Send channel message"
    assert attrs.examples == ["send channel message", "please send channel message"]
    assert attrs.generation.strategy == "heuristic"
    assert attrs.generation.fallback_reason =~ "invalid_model_field"
  end

  test "model descriptor fields are redacted before persistence" do
    attrs = generate_with(SecretEchoLLM)

    assert_received :secret_echo_llm_called
    refute inspect(attrs) =~ "sk-testsecret"
    refute inspect(attrs) =~ "secret://"
    assert attrs.generation.strategy == "model"
  end

  defp generate_with(client) do
    Optimizer.generate(SendChannelMessage, :model,
      llm_client: client,
      llm_opts: [test_pid: self()]
    )
  end

  defp restore(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore(key, value), do: Application.put_env(:allbert_assist, key, value)
end
