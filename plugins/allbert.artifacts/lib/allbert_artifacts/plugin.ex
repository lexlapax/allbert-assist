defmodule AllbertArtifacts.Plugin do
  @moduledoc """
  Artifacts Browser plugin entrypoint.

  The plugin contributes operator browsing surfaces for Artifacts Central. It
  does not own artifact storage, permissions, settings, or scheme authority.
  """

  use AllbertAssist.Plugin

  @impl true
  def plugin_id, do: "allbert.artifacts"

  @impl true
  def display_name, do: "Artifacts Browser"

  @impl true
  def version, do: "0.50.1"

  @impl true
  def validate(_opts), do: :ok

  @impl true
  def apps, do: [AllbertArtifacts.App]
end
