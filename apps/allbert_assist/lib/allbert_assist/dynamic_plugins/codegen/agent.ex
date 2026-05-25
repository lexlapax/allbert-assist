defmodule AllbertAssist.DynamicPlugins.Codegen.Agent do
  @moduledoc """
  JidoBacked coordinator for v0.37 dynamic draft requests.

  Draft metadata and objective events are authoritative. This agent stores only
  rebuildable diagnostics for request routing and does not provide an execution
  or security boundary.
  """

  alias AllbertAssist.DynamicPlugins.Codegen.Commands
  alias AllbertAssist.JidoBacked

  @request_draft "allbert.dynamic_codegen.request_draft"

  use JidoBacked,
    name: "allbert_dynamic_codegen",
    description: "Coordinates explicit dynamic draft requests.",
    schema: [
      last_requested_slug: [type: :string, default: nil],
      last_gap_id: [type: :string, default: nil],
      last_rebuilt_at: [type: :string, default: nil],
      last_command: [type: :atom, default: nil],
      last_result: [type: :any, default: nil],
      last_error: [type: :string, default: nil],
      last_summary: [type: :any, default: nil]
    ],
    signal_routes: [
      {@request_draft, Commands.RequestDraft}
    ]

  @doc false
  @impl true
  def rebuild_state(opts) do
    now =
      opts
      |> Keyword.get(:now, DateTime.utc_now())
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    {:ok,
     %{
       last_requested_slug: nil,
       last_gap_id: nil,
       last_rebuilt_at: now,
       last_command: :rebuild,
       last_result: {:ok, :ready},
       last_error: nil,
       last_summary: %{status: :ready}
     }}
  end

  @doc false
  @impl true
  def command_modules, do: [Commands.RequestDraft]

  @doc false
  def request_draft(attrs, context \\ %{}, opts \\ []) when is_map(attrs) and is_map(context) do
    server = Keyword.get(opts, :server, __MODULE__)

    JidoBacked.dispatch(server, @request_draft, %{attrs: attrs, context: context},
      source: "/allbert/dynamic_codegen",
      timeout: :infinity,
      expected_command: :request_draft
    )
  end
end
