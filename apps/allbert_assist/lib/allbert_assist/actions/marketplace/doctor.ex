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
      doctor: [type: :map, required: true],
      diagnostics: [type: {:list, :map}, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Marketplace.Support
  alias AllbertAssist.Marketplace
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    if Support.marketplace_enabled?() do
      decision = PermissionGate.authorize(:read_only, context)

      if PermissionGate.allowed?(decision) do
        {:ok, doctor} =
          params
          |> normalize_params()
          |> Map.to_list()
          |> Marketplace.doctor()

        {:ok, completed(doctor, decision)}
      else
        {:ok, denied(decision)}
      end
    else
      {:ok, disabled()}
    end
  end

  defp completed(doctor, decision) do
    status = if doctor.live_check_status == :ok, do: :completed, else: :failed

    %{
      message: "Marketplace doctor live check #{doctor.live_check_status}.",
      status: status,
      permission_decision: decision,
      doctor: doctor,
      result: doctor,
      diagnostics: doctor.diagnostics,
      actions: [
        %{
          name: name(),
          status: status,
          permission: :read_only,
          permission_decision: decision,
          marketplace_metadata: %{
            live_check_status: doctor.live_check_status,
            error_category: doctor.error_category,
            diagnostics: doctor.diagnostics
          }
        }
      ]
    }
  end

  defp denied(decision) do
    %{
      message: "Marketplace doctor denied: #{inspect(decision.reason)}.",
      status: PermissionGate.response_status(decision),
      permission_decision: decision,
      doctor: %{},
      result: %{},
      diagnostics: [],
      actions: [
        %{
          name: name(),
          status: :denied,
          permission: :read_only,
          permission_decision: decision,
          marketplace_metadata: %{error: :permission_denied}
        }
      ]
    }
  end

  defp disabled do
    response = Support.disabled(name(), :read_only)

    response
    |> Map.put(:doctor, %{})
    |> Map.put(:result, %{})
  end

  defp normalize_params(params) when is_map(params) do
    opts =
      %{
        verbose: Map.get(params, :verbose) || Map.get(params, "verbose") || false
      }

    case Map.get(params, :expected_schema_version) || Map.get(params, "expected_schema_version") do
      nil -> opts
      version -> Map.put(opts, :expected_schema_version, version)
    end
  end

  defp normalize_params(_params), do: %{verbose: false}
end
