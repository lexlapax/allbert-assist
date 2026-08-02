defmodule AllbertAssist.Models.ReqLLMRetryBoundaryTest do
  use ExUnit.Case, async: true

  @moduletag :pure_async

  alias ReqLLM.Providers.OpenAI

  test "a zero-retry non-streaming model request makes one physical transport attempt" do
    parent = self()

    adapter = fn request ->
      send(parent, :provider_transport_attempt)
      {request, %Req.TransportError{reason: :closed}}
    end

    {:ok, model} = ReqLLM.model("openai:gpt-4-turbo")

    assert {:ok, request} =
             OpenAI.prepare_request(:chat, model, "Hello",
               api_key: "test-key",
               max_retries: 0,
               req_http_options: [adapter: adapter]
             )

    assert request.options[:max_retries] == 0

    assert {:error,
            %ReqLLM.Error.API.Request{
              cause: %Req.TransportError{reason: :closed}
            }} = Req.request(request)

    assert_receive :provider_transport_attempt
    refute_receive :provider_transport_attempt, 20
  end
end
