defmodule AllbertAssistWeb.PackReadiness.Component do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  @spec mount(Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(socket) do
    socket =
      socket
      |> Phoenix.LiveView.attach_hook(
        :allbert_pack_component_event,
        :handle_event,
        &validate_event/3
      )
      |> Phoenix.LiveView.attach_hook(
        :allbert_pack_component_async,
        :handle_async,
        &validate_async/3
      )

    {:ok, socket}
  end

  @spec prepare_update(map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, map(), Phoenix.LiveView.Socket.t()} | {:error, Phoenix.LiveView.Socket.t()}
  def prepare_update(assigns, socket) when is_map(assigns) do
    supplied_epoch =
      Map.get(assigns, :allbert_pack_epoch) ||
        get_in(assigns, [:renderer_context, :allbert_pack_epoch])

    stored_epoch = socket.assigns[:allbert_pack_epoch]

    with true <- is_nil(stored_epoch) or supplied_epoch == stored_epoch,
         epoch when not is_nil(epoch) <- supplied_epoch || stored_epoch,
         :ok <- AllbertAssistWeb.PackReadiness.validate(epoch) do
      {:ok, Map.put(assigns, :allbert_pack_epoch, epoch),
       assign(socket, :allbert_pack_epoch, epoch)}
    else
      _reason ->
        AllbertAssistWeb.PackReadiness.disconnect()
        {:error, socket}
    end
  end

  defp validate_event(_event, _params, socket), do: lifecycle_result(socket)
  defp validate_async(_name, _result, socket), do: lifecycle_result(socket)

  defp lifecycle_result(socket) do
    case AllbertAssistWeb.PackReadiness.validate(socket.assigns[:allbert_pack_epoch]) do
      :ok ->
        {:cont, socket}

      {:error, _reason} ->
        AllbertAssistWeb.PackReadiness.disconnect()
        {:halt, socket}
    end
  end
end
