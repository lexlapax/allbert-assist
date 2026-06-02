defmodule AllbertAssist.Actions.Marketplace.InstallBundle do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :marketplace_install,
    exposure: :internal,
    execution_mode: :marketplace_install_bundle,
    skill_backed?: false,
    confirmation: :not_required,
    resumable?: true,
    name: "install_marketplace_bundle",
    description: "Install a shipped Marketplace Lite bundle disabled and untrusted.",
    category: "marketplace",
    tags: ["marketplace", "install"],
    schema: [
      entry_id: [type: :string, required: true],
      version: [type: :string, required: false]
    ],
    output_schema: []

  alias AllbertAssist.Actions.Marketplace.Support
  alias AllbertAssist.Marketplace

  @impl true
  def run(params, context) do
    request = request(params)

    Support.gated_write(name(), :marketplace_install_bundle, request, context, fn decision ->
      opts = if request.version, do: [version: request.version], else: []

      case Marketplace.install_bundle(request.entry_id, opts) do
        {:ok, result} ->
          Support.completed(
            name(),
            :marketplace_install,
            decision,
            result,
            "Marketplace bundle installed."
          )

        {:error, diagnostic} ->
          Support.failed(name(), :marketplace_install, decision, diagnostic)
      end
    end)
  end

  defp request(params) do
    %{
      entry_id: Support.field(params, :entry_id, ""),
      version: Support.field(params, :version)
    }
  end
end
