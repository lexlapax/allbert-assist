defmodule Mix.Tasks.Allbert.Intent do
  @moduledoc """
  Inspect the intent router (v0.54).

  ## Usage

      mix allbert.intent doctor

  `doctor` probes the local embedder and reports the router strategy, configured
  profiles, and utterance-index state in a redacted ADR 0047 envelope.
  """
  @shortdoc "Inspect the intent router (doctor)"

  use Mix.Task

  alias AllbertAssist.Intent.Router.Doctor

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    dispatch(args)
  end

  defp dispatch(["doctor"]) do
    {:ok, envelope} = Doctor.diagnose()
    print_doctor(envelope)
  end

  defp dispatch(_args), do: Mix.raise("Usage: mix allbert.intent doctor")

  defp print_doctor(e) do
    Mix.shell().info("""
    intent router doctor status=#{e.status}
    strategy=#{e.strategy}
    embedding_profile=#{e.embedding_profile} endpoint=#{e.embedding_endpoint} dim=#{e.embedding_dim}
    model_profile=#{e.model_profile} escalation=#{e.escalation_profile}
    index status=#{e.index_status} size=#{e.index_size} built_at=#{e.index_built_at}
    """)
  end
end
