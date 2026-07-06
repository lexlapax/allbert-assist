defmodule AllbertAssist.Actions.FirstModel.Detect do
  @moduledoc """
  Detect the first-model state (v0.62 M4, ADR 0078). Read-only, localhost-only:
  the three-way Ollama probe + hardware-floor + BYOK check resolve one of the
  seven first-model states the entry points consume. No install, no pull, no
  external egress — those are the confirmation-gated `InstallOllama` /
  `PullModel` actions.
  """

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :settings_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "first_model_detect",
    description: "Detect Ollama runtime/model state and the resolved first-model state.",
    category: "first_model",
    tags: ["first_model", "models", "read_only", "operator"],
    schema: [
      surface: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      first_model: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Operator.Support
  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.FirstModel.Hardware
  alias AllbertAssist.FirstModel.Ollama

  @impl true
  def run(_params, context) do
    Support.read_only(name(), context, fn permission_decision ->
      floor = Ollama.curated_floor_gb()

      state =
        FirstRun.first_model_state(
          ollama_probe: fn -> Ollama.probe() end,
          hardware_ok?: fn -> Hardware.meets_floor?(floor) end
        )

      report = %{
        state: state,
        curated_model: Ollama.curated_model(),
        curated_floor_gb: floor,
        ram_gb: Hardware.total_ram_gb(),
        binary_present: Ollama.binary_present?()
      }

      {:ok,
       %{
         message: "First-model state: #{state}.",
         surface_payload: "First-model state: #{state}.",
         status: :completed,
         permission_decision: permission_decision,
         first_model: report,
         actions: [Support.action(name(), :completed, permission_decision, report)]
       }}
    end)
  end
end
