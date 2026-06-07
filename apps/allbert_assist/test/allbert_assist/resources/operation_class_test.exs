defmodule AllbertAssist.Resources.OperationClassTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Resources.OperationClass

  test "recognizes voice origin kinds" do
    assert {:ok, :audio_capture} = OperationClass.origin_kind(:audio_capture)
    assert {:ok, :audio_file} = OperationClass.origin_kind("audio_file")
    assert {:ok, :image_input} = OperationClass.origin_kind("image_input")
  end

  test "recognizes voice operation classes and default access modes" do
    assert {:ok, :microphone_capture} = OperationClass.operation_class(:microphone_capture)
    assert {:ok, :voice_transcribe} = OperationClass.operation_class("voice_transcribe")
    assert {:ok, :voice_synthesize} = OperationClass.operation_class(:voice_synthesize)
    assert {:ok, :image_input} = OperationClass.operation_class(:image_input)
    assert {:ok, :image_generate} = OperationClass.operation_class("image_generate")

    assert OperationClass.default_access_mode(:microphone_capture) == :read
    assert OperationClass.default_access_mode(:voice_transcribe) == :read
    assert OperationClass.default_access_mode(:voice_synthesize) == :write
    assert OperationClass.default_access_mode(:image_input) == :read
    assert OperationClass.default_access_mode(:image_generate) == :write
  end

  test "recognizes media capture scope kinds" do
    assert {:ok, :audio_capture} = OperationClass.scope_kind("audio_capture")
    assert {:ok, :image_input} = OperationClass.scope_kind("image_input")
  end
end
