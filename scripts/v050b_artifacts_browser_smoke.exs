defmodule Allbert.V050bArtifactsBrowserSmoke do
  @moduledoc false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Settings

  @fixture_bytes "v050b-artifacts-browser-smoke-fixture"
  @fixture_thread_id "thread-v050b-artifacts-browser-smoke"
  @fixture_signal_id "signal-v050b-artifacts-browser-smoke"
  @fixture_origin "v050b_browser_smoke"
  @fixture_mime "text/plain"
  @fixture_created_at "2026-06-09T00:00:00Z"

  def run(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: [seed_only: :boolean])

    unless invalid == [] and rest == [] and Keyword.get(opts, :seed_only, false) do
      Mix.raise("Usage: mix run scripts/v050b_artifacts_browser_smoke.exs --seed-only")
    end

    validate_allbert_home!()
    Mix.Task.run("app.start")
    configure_artifacts!()

    {:ok, %{status: :completed, artifact: artifact}} =
      Runner.run(
        "put_artifact",
        %{
          bytes: @fixture_bytes,
          metadata: %{
            mime: @fixture_mime,
            origin: @fixture_origin,
            created_at: @fixture_created_at
          }
        },
        context()
      )

    query =
      URI.encode_query(%{
        "destination" => "app:allbert_artifacts",
        "artifact_type" => @fixture_mime,
        "artifact_origin" => @fixture_origin,
        "artifact_thread" => @fixture_thread_id,
        "artifact_since" => "2026-06-01"
      })

    Mix.shell().info("ARTIFACT_SHA=#{artifact.sha256}")
    Mix.shell().info("THREAD_ID=#{@fixture_thread_id}")
    Mix.shell().info("WORKSPACE_URL=/workspace?#{query}")
    Mix.shell().info("DETAIL_URL=/apps/artifacts/#{artifact.sha256}")
  end

  defp validate_allbert_home! do
    home = System.get_env("ALLBERT_HOME")

    unless is_binary(home) and String.trim(home) != "" do
      Mix.raise("Set ALLBERT_HOME to a disposable temporary directory before running this smoke.")
    end

    expanded = Path.expand(home)
    real_home = Path.expand("~/.allbert")
    tmp_roots = [System.tmp_dir!(), "/tmp", "/private/tmp"] |> Enum.map(&Path.expand/1)

    cond do
      expanded == real_home ->
        Mix.raise("Refusing to use real ~/.allbert for v0.50b browser smoke validation.")

      not Enum.any?(tmp_roots, &tmp_child?(expanded, &1)) ->
        Mix.raise("ALLBERT_HOME must be under a temporary directory for v0.50b validation.")

      true ->
        expanded
    end
  end

  defp tmp_child?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp configure_artifacts! do
    put!("artifacts.enabled", true)
    put!("artifacts.retention_enabled", true)
    put!("permissions.artifact_read", "allowed")
    put!("permissions.artifact_write", "allowed")
    put!("permissions.artifact_delete", "needs_confirmation")
  end

  defp put!(key, value) do
    case Settings.put(key, value, %{audit?: false}) do
      {:ok, _setting} -> :ok
      {:error, reason} -> Mix.raise("Failed to set #{key}: #{inspect(reason)}")
    end
  end

  defp context do
    %{
      actor: "local",
      user_id: "local",
      channel: :cli,
      surface: "v050b_browser_smoke",
      request: %{
        operator_id: "local",
        user_id: "local",
        thread_id: @fixture_thread_id,
        input_signal_id: @fixture_signal_id,
        channel: :cli,
        source: :v050b_artifacts_browser_smoke
      }
    }
  end
end

Allbert.V050bArtifactsBrowserSmoke.run(System.argv())
