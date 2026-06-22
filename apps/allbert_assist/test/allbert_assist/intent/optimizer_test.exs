defmodule AllbertAssist.Intent.Router.OptimizerTest do
  @moduledoc "v0.54 M9.3c — descriptor store + optimize/coverage (heuristic, offline)."
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Intent.Router.DescriptorResolver
  alias AllbertAssist.Intent.Router.DescriptorStore
  alias AllbertAssist.Intent.Router.Optimizer
  alias AllbertAssist.Paths
  alias AllbertAssist.TestSupport.ProviderPreconditions

  setup do
    original_home = System.get_env("ALLBERT_HOME")
    original_paths = Application.get_env(:allbert_assist, Paths)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-opt-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.rm_rf!(home)
    System.put_env("ALLBERT_HOME", home)

    Application.delete_env(:allbert_assist, Paths)
    ProviderPreconditions.ensure_notes_files_descriptors!()

    on_exit(fn ->
      if original_home,
        do: System.put_env("ALLBERT_HOME", original_home),
        else: System.delete_env("ALLBERT_HOME")

      if original_paths,
        do: Application.put_env(:allbert_assist, Paths, original_paths),
        else: Application.delete_env(:allbert_assist, Paths)

      File.rm_rf!(home)
    end)

    :ok
  end

  test "store put/load round-trips a generated descriptor for an uncovered agent action" do
    {:ok, path} =
      DescriptorStore.put(:generated, %{
        app_id: :allbert,
        action_name: "show_app",
        label: "Show app",
        examples: ["show app"],
        synonyms: ["app details"],
        vocabulary: %{
          phrases: ["show app"],
          negative_phrases: ["hide app"],
          allow_single_token_match: false
        },
        required_slots: []
      })

    assert path =~ "/intents/generated/allbert/show_app.yaml"
    refute String.ends_with?(path, ".exs")
    assert File.read!(path) =~ "schema_version: 1"

    loaded = DescriptorStore.load(:generated)

    assert Enum.any?(
             loaded,
             &(&1.action_name == "show_app" and &1.vocabulary.phrases == ["show app"])
           )

    # the resolver surfaces the generated descriptor
    assert DescriptorResolver.resolve() |> Enum.any?(&(&1.action_name == "show_app"))
  end

  test "store ignores executable and invalid descriptor payloads fail-closed" do
    generated = DescriptorStore.dir(:generated)
    File.mkdir_p!(Path.join(generated, "allbert"))
    File.write!(Path.join([generated, "allbert", "unsafe.exs"]), "%{action_name: \"show_app\"}\n")
    File.write!(Path.join([generated, "allbert", "broken.yaml"]), "not: [valid\n")

    refute DescriptorStore.read_attrs(:generated)
           |> Enum.any?(
             &((Map.get(&1, :action_name) || Map.get(&1, "action_name")) == "show_app")
           )
  end

  test "optimize generates descriptors for uncovered agent actions (heuristic, no rebuild)" do
    before_cov = Optimizer.coverage()

    result = Optimizer.optimize(strategy: :heuristic, rebuild: false)
    after_cov = Optimizer.coverage()

    if before_cov.missing > 0 do
      assert after_cov.missing < before_cov.missing
      assert result.generated != []
    else
      assert after_cov.missing == 0
      assert result.generated == []
    end

    assert after_cov.generated >= length(result.generated)
  end

  test "an operator disable override removes an action from the resolved set" do
    assert DescriptorResolver.resolve() |> Enum.any?(&(&1.action_name == "write_note"))

    {:ok, _path} =
      DescriptorStore.put(:overrides, %{
        app_id: :notes_files,
        action_name: "write_note",
        disabled: true
      })

    refute DescriptorResolver.resolve() |> Enum.any?(&(&1.action_name == "write_note"))
  end

  test "promote moves a review descriptor to generated (review is inert, generated loads)" do
    attrs = %{
      app_id: :allbert,
      action_name: "show_app",
      label: "Show app",
      examples: ["show app"],
      synonyms: ["app details"],
      required_slots: []
    }

    {:ok, _path} = DescriptorStore.put(:review, attrs)
    assert DescriptorStore.dir(:review) =~ "/intents/learned/review"
    refute DescriptorResolver.resolve() |> Enum.any?(&(&1.action_name == "show_app"))

    {:ok, _dest} = DescriptorStore.promote(:review, :generated, :allbert, "show_app")
    assert DescriptorResolver.resolve() |> Enum.any?(&(&1.action_name == "show_app"))
  end
end
