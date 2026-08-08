defmodule AllbertComposition.GateOwnerManifest do
  @moduledoc """
  Gate-owner contribution for the descriptorless composition support app.

  Composition has no runtime Pack descriptor because it owns product assembly,
  not product capability. Its OTP application declaration points gate tooling
  at this inert manifest instead.
  """

  def test_lanes do
    [
      %{
        owner_id: :composition,
        application: :allbert_composition,
        cwd: "apps/allbert_composition",
        production_source_roots: ["apps/allbert_composition/lib"],
        test_roots: ["apps/allbert_composition/test"],
        test_support_roots: [],
        allowed_primary_lanes: [
          :pure_async,
          :app_env_serial,
          :global_process_serial,
          :external_runtime_serial
        ],
        aggregate_policy: :allbert_test_raw,
        target_resolver: {AllbertAssist.DevGates.GateTargetResolver, :resolve},
        historical_metrics_aliases: ["composition"]
      }
    ]
  end
end
