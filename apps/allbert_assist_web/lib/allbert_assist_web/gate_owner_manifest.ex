defmodule AllbertAssistWeb.GateOwnerManifest do
  @moduledoc """
  Gate-owner contribution for the descriptorless Phoenix interface app.

  The web application remains an interface over the runtime and therefore owns
  test execution metadata without becoming a capability Pack.
  """

  @spec test_lanes() :: [map()]
  def test_lanes do
    [
      %{
        owner_id: :web,
        application: :allbert_assist_web,
        cwd: "apps/allbert_assist_web",
        production_source_roots: ["apps/allbert_assist_web/lib"],
        test_roots: ["apps/allbert_assist_web/test"],
        test_support_roots: ["apps/allbert_assist_web/test/support"],
        allowed_primary_lanes: [
          :pure_async,
          :db_serial,
          :db_partition_safe,
          :app_env_serial,
          :home_fs_serial,
          :global_process_serial,
          :external_runtime_serial,
          :liveview_serial,
          :security_eval_serial
        ],
        aggregate_policy: :allbert_test_raw,
        target_resolver: {AllbertAssist.DevGates.GateTargetResolver, :resolve},
        historical_metrics_aliases: ["web"]
      }
    ]
  end
end
