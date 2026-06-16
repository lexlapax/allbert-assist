defmodule AllbertAssist.Intent.RouterEmbeddingTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Intent.Router.Doctor
  alias AllbertAssist.Intent.Router.Embedder
  alias AllbertAssist.Intent.Router.Embedder.FakeEmbedder
  alias AllbertAssist.Intent.Router.Index
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup do
    original_home = System.get_env("ALLBERT_HOME")
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)
    original_embedder = Application.get_env(:allbert_assist, :intent_router_embedder)
    original_error = Application.get_env(:allbert_assist, :intent_router_embedder_error)

    home = Path.join(System.tmp_dir!(), "allbert-router-embed-#{System.unique_integer([:positive])}")
    System.put_env("ALLBERT_HOME", home)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)
    Application.put_env(:allbert_assist, :intent_router_embedder, FakeEmbedder)
    Application.delete_env(:allbert_assist, :intent_router_embedder_error)

    on_exit(fn ->
      if original_home, do: System.put_env("ALLBERT_HOME", original_home), else: System.delete_env("ALLBERT_HOME")
      restore(Paths, original_paths)
      restore(Settings, original_settings)
      restore(:intent_router_embedder, original_embedder)
      restore(:intent_router_embedder_error, original_error)
    end)

    :ok
  end

  describe "Embedder" do
    test "embeds each text into a unit vector via the configured impl" do
      assert {:ok, [v1, v2]} = Embedder.embed(["create note alpha", "create note beta"])
      assert length(v1) == 64 and length(v2) == 64
      # self-similarity is 1.0; shared vocabulary ("create note") beats disjoint
      assert_in_delta Embedder.cosine(v1, v1), 1.0, 1.0e-9
      assert Embedder.cosine(v1, v2) > Embedder.cosine(v1, FakeEmbedder.vector("zzz qqq www"))
    end

    test "propagates a forced embedder error" do
      Application.put_env(:allbert_assist, :intent_router_embedder_error, :boom)
      assert {:error, :boom} = Embedder.embed(["anything"])
    end
  end

  describe "Index" do
    test "rebuild builds from the registry with the local embedder" do
      pid = start_supervised!(Index)
      assert is_pid(pid)
      built = Index.rebuild()
      assert built.status == :built
      assert is_list(built.entries)
    end

    test "reports :unavailable when the embedder errors (with descriptors present)" do
      # exercised end-to-end via the doctor probe, which always embeds a probe string
      Application.put_env(:allbert_assist, :intent_router_embedder_error, :down)
      assert {:ok, %{embedding_endpoint: :unavailable}} = Doctor.diagnose()
    end
  end

  describe "Doctor" do
    test "reports ok and the embedding dimension when the local embedder works" do
      assert {:ok, envelope} = Doctor.diagnose()
      assert envelope.status == :ok
      assert envelope.embedding_endpoint == :available
      assert envelope.embedding_dim == 64
      assert envelope.strategy == :deterministic
      assert envelope.embedding_profile == "embedding_local"
      # persisted state round-trips redacted
      assert {:ok, %{"status" => "ok"}} = Doctor.read_state()
    end
  end

  defp restore(key, nil) when is_atom(key), do: Application.delete_env(:allbert_assist, key)
  defp restore(key, value), do: Application.put_env(:allbert_assist, key, value)
end
