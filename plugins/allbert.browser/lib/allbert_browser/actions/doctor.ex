defmodule AllbertBrowser.Actions.Doctor do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :browser_diagnostic,
    skill_backed?: false,
    confirmation: :not_required,
    plugin_id: "allbert.browser",
    name: "browser_doctor",
    description: "Verify browser driver availability with a redacted live-check envelope.",
    category: "browser",
    tags: ["browser", "doctor", "read_only"],
    schema: [verbose: [type: :boolean, required: false]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertBrowser.{Actions, Doctor}

  @impl true
  def run(_params, context) do
    decision = Actions.authorize(:read_only, context)

    with true <- Actions.allowed?(decision),
         {:ok, result} <- Doctor.run() do
      {:ok,
       %{
         message: "Browser doctor live check #{result.live_check_status}.",
         status: :completed,
         permission_decision: decision,
         doctor: result,
         actions: [Actions.action("browser_doctor", :completed, :read_only, decision, result)]
       }}
    else
      false -> Actions.denied("browser_doctor", :read_only, decision, :permission_denied)
      {:error, reason} -> Actions.denied("browser_doctor", :read_only, decision, reason)
    end
  end
end
