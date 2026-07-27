defmodule AllbertAssist.FirstRun.UsableModelTest do
  use ExUnit.Case, async: true

  @moduletag :pure_async

  alias AllbertAssist.FirstRun.UsableModel

  test "healthy configured local wins over configured hosted" do
    settings = settings()
    doctor = fn "local" -> {:ok, %{endpoint_ok: true, model_available: true}} end

    assert {:ok, %{profile: "local", provider_class: :local}} =
             UsableModel.select(settings: settings, doctor: doctor, tags: [])
  end

  test "curated pulled profile is the bounded fallback when doctor is not healthy" do
    doctor = fn _profile -> {:ok, %{endpoint_ok: true, model_available: false}} end

    assert {:ok, %{profile: "local", provider_class: :local}} =
             UsableModel.select(
               settings: settings(),
               doctor: doctor,
               tags: ["llama3.2:3b"],
               curated_model: "llama3.2:3b"
             )
  end

  test "hosted selection is presence-only and follows explicit preference first" do
    settings = put_in(settings(), ["model_preferences", "primary"], "anthropic_fast")
    doctor = fn _profile -> {:error, :unreachable} end

    assert {:ok,
            %{
              profile: "anthropic_fast",
              provider: "anthropic",
              provider_class: :hosted,
              verification: :configured_unverified
            }} = UsableModel.select(settings: settings, doctor: doctor, tags: [])
  end

  test "stable provider order breaks hosted ties and unknown providers sort last" do
    settings =
      settings()
      |> put_in(["model_preferences", "primary"], nil)
      |> put_in(["model_preferences", "tasks", "direct_answer"], [])

    assert {:ok, %{provider: "openai"}} = UsableModel.select_hosted(settings)
  end

  test "raw explicit provider false blocks a configured hosted profile" do
    settings =
      settings()
      |> put_in(["model_preferences", "primary"], "fast")
      |> put_in(["model_preferences", "tasks", "direct_answer"], ["fast"])
      |> Map.update!("providers", &Map.take(&1, ["openai"]))
      |> Map.update!("model_profiles", &Map.take(&1, ["fast"]))

    user_settings = %{"providers" => %{"openai" => %{"enabled" => false}}}

    assert {:error, :no_usable_model} =
             UsableModel.select_hosted(settings, user_settings)
  end

  defp settings do
    %{
      "model_preferences" => %{
        "primary" => "local",
        "tasks" => %{"direct_answer" => ["local"]}
      },
      "providers" => %{
        "local_ollama" => %{
          "enabled" => true,
          "endpoint_kind" => "local_endpoint",
          "type" => "openai_compatible"
        },
        "openai" => hosted_provider("openai"),
        "anthropic" => hosted_provider("anthropic"),
        "custom" => hosted_provider("zzz")
      },
      "model_profiles" => %{
        "local" => text_profile("local_ollama", "llama3.2:3b"),
        "fast" => text_profile("openai", "gpt"),
        "anthropic_fast" => text_profile("anthropic", "claude"),
        "custom_fast" => text_profile("custom", "custom")
      }
    }
  end

  defp hosted_provider(type) do
    %{
      "enabled" => false,
      "endpoint_kind" => "credentialed_remote",
      "credential_status" => :configured,
      "type" => type
    }
  end

  defp text_profile(provider, model) do
    %{"provider" => provider, "model" => model, "capabilities" => ["text_generation"]}
  end
end
