defmodule AllbertAssist.FirstRun.DisclosureTest do
  use ExUnit.Case, async: false

  @moduletag :app_env_serial

  alias AllbertAssist.FirstRun.Disclosure
  alias AllbertAssist.Paths

  setup do
    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-disclosure-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    previous = Application.get_env(:allbert_assist, Paths)
    Application.put_env(:allbert_assist, Paths, home: home)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:allbert_assist, Paths, previous),
        else: Application.delete_env(:allbert_assist, Paths)

      File.rm_rf!(home)
    end)

    :ok
  end

  test "each surface acknowledges independently and restart does not repeat" do
    :ok = Disclosure.mark_pending(selection(:local))

    assert Disclosure.pending?(:web)
    assert Disclosure.pending?(:tui)
    assert Disclosure.pending?(:cli)

    assert :ok = Disclosure.render_and_ack(:cli, fn text -> send(self(), {:rendered, text}) end)
    assert_receive {:rendered, text}
    assert text =~ "Inference stays on this device"
    refute Disclosure.pending?(:cli)
    assert Disclosure.pending?(:web)

    assert :ok = Disclosure.render_and_ack(:cli, fn _text -> flunk("repeated") end)
  end

  test "failed output leaves hosted disclosure pending before transport" do
    :ok = Disclosure.mark_pending(selection(:hosted))

    assert Disclosure.hosted_pending?(:cli)

    assert {:error, {:disclosure_render_failed, RuntimeError}} =
             Disclosure.render_and_ack(:cli, fn _text -> raise "closed output" end)

    assert Disclosure.hosted_pending?(:cli)
    assert Disclosure.text(:cli) =~ "will leave this device for openai"

    assert {:error, {:disclosure_render_failed, :closed}} =
             Disclosure.render_and_ack(:cli, fn _text -> {:error, :closed} end)

    assert Disclosure.hosted_pending?(:cli)
  end

  test "web acknowledgement requires the exact mounted delivery handle" do
    :ok = Disclosure.mark_pending(selection(:hosted))
    assert {:ok, %{text: text, handle: handle}} = Disclosure.prepare_web_delivery()
    assert text =~ "will leave this device"

    assert {:error, :stale_delivery_handle} = Disclosure.acknowledge_web("forged")
    assert Disclosure.hosted_pending?(:web)

    assert :ok = Disclosure.acknowledge_web(handle)
    refute Disclosure.pending?(:web)
  end

  defp selection(:local) do
    %{profile: "local", provider: "local_ollama", provider_class: :local}
  end

  defp selection(:hosted) do
    %{profile: "fast", provider: "openai", provider_class: :hosted}
  end
end
