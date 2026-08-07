defmodule AllbertAssist.Pack.Kernel do
  @moduledoc """
  Pack descriptor for the dependency-minimal Allbert kernel application.
  """

  @behaviour AllbertAssist.Pack

  alias AllbertAssist.Pack.Descriptor

  @application_version Mix.Project.config()[:version]
  @empty_callbacks [
    :apps,
    :actions,
    :settings_fragments,
    :settings_migrations,
    :channels,
    :surfaces,
    :skill_roots,
    :home_roots,
    :jobs,
    :stores,
    :prompt_rules,
    :intent_descriptors,
    :cli_groups,
    :release_assets,
    :test_lanes
  ]

  @impl true
  def descriptor do
    %Descriptor{
      schema_version: 1,
      id: "allbert_kernel",
      application: :allbert_kernel,
      application_version: @application_version,
      capability_tier: :kernel,
      provenance: %{source: :signed_release, component: "beam-allbert-kernel"},
      registry_order: 0
    }
  end

  for callback <- @empty_callbacks do
    @impl true
    def unquote(callback)(), do: []
  end
end
