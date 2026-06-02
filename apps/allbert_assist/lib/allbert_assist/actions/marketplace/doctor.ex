defmodule AllbertAssist.Actions.Marketplace.Doctor do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :marketplace_diagnostic,
    skill_backed?: false,
    confirmation: :not_required,
    name: "marketplace_doctor",
    description: "Check Marketplace Lite catalog and installed bundle state.",
    category: "marketplace",
    tags: ["marketplace", "doctor", "read_only", "internal"],
    schema: [
      verbose: [type: :boolean, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Marketplace

  @impl true
  def run(params, _context) do
    opts =
      params
      |> normalize_params()
      |> Map.to_list()

    Marketplace.doctor(opts)
  end

  defp normalize_params(params) when is_map(params) do
    %{
      verbose: Map.get(params, :verbose) || Map.get(params, "verbose") || false
    }
  end

  defp normalize_params(_params), do: %{verbose: false}
end
