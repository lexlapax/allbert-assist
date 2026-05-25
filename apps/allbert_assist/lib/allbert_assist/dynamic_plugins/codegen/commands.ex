defmodule AllbertAssist.DynamicPlugins.Codegen.Commands do
  @moduledoc false

  @doc false
  def finish(command, result, state) do
    case result do
      {:ok, value} ->
        {:ok,
         state
         |> Map.merge(%{
           last_command: command,
           last_result: {:ok, value},
           last_error: nil,
           last_summary: summary(value)
         })
         |> maybe_put(:last_requested_slug, get_in(value, [:draft, :slug]))
         |> maybe_put(:last_gap_id, get_in(value, [:gap, "id"]))}

      {:error, reason} ->
        {:ok,
         state
         |> Map.merge(%{
           last_command: command,
           last_result: {:error, reason},
           last_error: inspect(reason),
           last_summary: %{status: :error}
         })}
    end
  end

  defp summary(%{draft: draft, gap: gap}) do
    %{status: :requested, draft: Map.take(draft, [:slug, :revision, :tier]), gap_id: gap["id"]}
  end

  defp summary(_value), do: %{status: :unknown}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

defmodule AllbertAssist.DynamicPlugins.Codegen.Commands.RequestDraft do
  @moduledoc false

  use Jido.Action,
    name: "allbert_dynamic_codegen_request_draft",
    description: "Private dynamic-codegen draft request command."

  alias AllbertAssist.DynamicPlugins.Codegen.Commands
  alias AllbertAssist.DynamicPlugins.Codegen.Producer

  @impl true
  def run(%{attrs: attrs, context: request_context}, context) do
    state = Map.get(context, :state, %{})
    Commands.finish(:request_draft, Producer.request_draft(attrs, request_context), state)
  end
end
