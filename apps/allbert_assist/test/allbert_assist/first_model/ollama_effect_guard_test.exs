defmodule AllbertAssist.FirstModel.OllamaEffectGuardTest do
  use ExUnit.Case, async: false

  @moduletag :external_runtime_serial

  alias AllbertAssist.FirstModel.Ollama
  alias AllbertAssist.TestSupport.ReadyEffectContext

  setup {Req.Test, :verify_on_exit!}

  setup do
    previous = Application.get_env(:allbert_assist, :first_model_req_options)
    Application.put_env(:allbert_assist, :first_model_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:allbert_assist, :first_model_req_options, previous),
        else: Application.delete_env(:allbert_assist, :first_model_req_options)
    end)
  end

  test "a ready E1 reaches the localhost Req probe" do
    context = ReadyEffectContext.context()

    Req.Test.expect(__MODULE__, fn %{request_path: "/api/version"} = conn ->
      Req.Test.json(conn, %{"version" => "0.5.0"})
    end)

    assert Ollama.server_version(context) == {:ok, "0.5.0"}
  end

  test "missing and stale E1 contexts do not invoke the Req probe" do
    test_pid = self()
    context = ReadyEffectContext.context()
    barrier = ReadyEffectContext.server(context)

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, :transport_called)
      Req.Test.json(conn, %{"version" => "unexpected"})
    end)

    assert Ollama.server_version() == :error
    refute_received :transport_called

    :ok = ReadyEffectContext.replace(barrier)

    assert Ollama.server_version(context) == :error
    refute_received :transport_called
  end
end
