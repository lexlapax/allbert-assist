defmodule AllbertAssist.Voice.ProviderAdapterTest do
  use ExUnit.Case, async: true
  @moduletag :home_fs_serial

  alias AllbertAssist.Voice.Adapters
  alias AllbertAssist.Voice.ProviderAdapter

  test "selects adapter modules by deployment mode" do
    assert {:ok, Adapters.Fake} =
             ProviderAdapter.for_profile(%{media: %{"deployment_mode" => "fake"}})

    assert {:ok, Adapters.LocalEndpoint} =
             ProviderAdapter.for_profile(%{media: %{"deployment_mode" => "local_endpoint"}})

    assert {:ok, Adapters.BundledLocal} =
             ProviderAdapter.for_profile(%{media: %{"deployment_mode" => "bundled_local"}})

    assert {:ok, Adapters.RemoteCredentialed} =
             ProviderAdapter.for_profile(%{media: %{"deployment_mode" => "remote_credentialed"}})
  end

  test "unimplemented and non-native providers fail closed" do
    request = %{input_path: "/tmp/voice.wav", transcode_spec: %{output_path: "/tmp/voice.wav"}}

    assert {:error, :missing_local_voice_base_url} =
             ProviderAdapter.synthesize(
               %{media: %{"deployment_mode" => "local_endpoint"}},
               %{text: "hello", output_format: "wav"}
             )

    assert {:error, {:voice_adapter_unavailable, :bundled_local}} =
             ProviderAdapter.synthesize(
               %{media: %{"deployment_mode" => "bundled_local"}},
               %{text: "hello", output_format: "wav"}
             )

    assert {:error, {:voice_capability_not_native, "anthropic"}} =
             ProviderAdapter.transcribe(
               %{
                 provider_type: "anthropic",
                 media: %{"deployment_mode" => "remote_credentialed"}
               },
               request
             )
  end

  test "unknown deployment modes do not become atoms" do
    assert {:error, {:voice_adapter_unavailable, "future_mode"}} =
             ProviderAdapter.for_profile(%{media: %{"deployment_mode" => "future_mode"}})

    assert {:error, {:voice_adapter_unavailable, :unknown}} = ProviderAdapter.for_profile(%{})
  end
end
