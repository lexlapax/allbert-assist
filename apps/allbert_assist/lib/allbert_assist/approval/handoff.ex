defmodule AllbertAssist.Approval.Handoff do
  @moduledoc """
  Shared approval-handoff primitive selection for channel renderers.

  This module chooses a channel primitive from an already-effective channel
  descriptor. Renderers remain responsible for formatting the selected payload
  into provider wire shapes.
  """

  alias AllbertAssist.Confirmations.ObjectiveContext
  alias AllbertAssist.Intent.ApprovalHandoff

  @type primitive_kind :: :button | :typed_command | :link | :list

  @primitive_order [:button, :typed_command, :link, :list]
  @callback_actions [
    {"Approve", "approve"},
    {"Deny", "deny"},
    {"Show", "show"}
  ]

  @spec render(map(), map()) :: {:ok, {primitive_kind(), map()}} | {:error, term()}
  def render(handoff_payload, descriptor) when is_map(handoff_payload) and is_map(descriptor) do
    primitives = Map.get(descriptor, :primitives, Map.get(descriptor, "primitives", []))

    with :ok <- validate_primitives(primitives),
         {:ok, primitive} <- select_primitive(primitives, handoff_payload) do
      {:ok, {primitive, primitive_payload(primitive, handoff_payload)}}
    end
  end

  def render(_handoff_payload, _descriptor), do: {:error, :invalid_handoff}

  defp validate_primitives(primitives) when is_list(primitives) and primitives != [] do
    if Enum.all?(primitives, &(&1 in @primitive_order)) do
      :ok
    else
      {:error, :invalid_primitives}
    end
  end

  defp validate_primitives(_primitives), do: {:error, :invalid_primitives}

  defp select_primitive(primitives, handoff_payload) do
    @primitive_order
    |> Enum.find(&eligible?(&1, primitives, handoff_payload))
    |> case do
      nil -> {:error, :no_supported_primitive}
      primitive -> {:ok, primitive}
    end
  end

  defp eligible?(:link, primitives, handoff_payload),
    do: :link in primitives and is_binary(workspace_url(handoff_payload))

  defp eligible?(primitive, primitives, _handoff_payload), do: primitive in primitives

  defp primitive_payload(:button, handoff_payload) do
    %{
      text: approval_text(handoff_payload),
      buttons: callback_buttons(handoff_payload)
    }
  end

  defp primitive_payload(:typed_command, handoff_payload) do
    %{
      text: approval_text(handoff_payload),
      commands: typed_commands(handoff_payload)
    }
  end

  defp primitive_payload(:link, handoff_payload) do
    %{
      text: approval_text(handoff_payload),
      url: workspace_url(handoff_payload)
    }
  end

  defp primitive_payload(:list, handoff_payload) do
    %{
      text: approval_text(handoff_payload),
      numbered_options:
        @callback_actions
        |> Enum.with_index(1)
        |> Enum.map(fn {{label, action}, index} ->
          %{
            index: index,
            label: label,
            action: action,
            command: typed_command(action, handoff_payload)
          }
        end)
    }
  end

  defp approval_text(handoff_payload) do
    (ObjectiveContext.lines(handoff_payload) ++ ApprovalHandoff.lines(handoff_payload))
    |> case do
      [] -> ["Approval required."]
      lines -> lines
    end
    |> Enum.join("\n")
  end

  defp callback_buttons(handoff_payload) do
    Enum.map(@callback_actions, fn {label, action} ->
      %{label: label, callback_data: "allbert:v1:#{action}:#{confirmation_id(handoff_payload)}"}
    end)
  end

  defp typed_commands(handoff_payload) do
    Enum.map(@callback_actions, fn {_label, action} -> typed_command(action, handoff_payload) end)
  end

  defp typed_command(action, handoff_payload) do
    "ALLBERT:#{String.upcase(action)}:#{confirmation_id(handoff_payload)}"
  end

  defp confirmation_id(handoff_payload),
    do: Map.get(handoff_payload, :confirmation_id, Map.get(handoff_payload, "confirmation_id"))

  defp workspace_url(handoff_payload) do
    render_hints =
      Map.get(handoff_payload, :render_hints, Map.get(handoff_payload, "render_hints", %{}))

    Map.get(render_hints, :workspace_url, Map.get(render_hints, "workspace_url")) ||
      Map.get(handoff_payload, :workspace_url, Map.get(handoff_payload, "workspace_url"))
  end
end
