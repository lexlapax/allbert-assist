defmodule AllbertAssistWeb.LiveSocket do
  @moduledoc false

  use Phoenix.Socket

  channel "lvu:*", Phoenix.LiveView.UploadChannel
  channel "lv:*", Phoenix.LiveView.Channel

  @impl Phoenix.Socket
  def connect(params, socket, connect_info) do
    with {:ok, epoch} <- AllbertAssistWeb.PackReadiness.admit(),
         {:ok, socket} <- Phoenix.LiveView.Socket.connect(params, socket, connect_info) do
      info = Map.put(connect_info, :allbert_pack_epoch, epoch)
      {:ok, put_in(socket.private[:connect_info], info)}
    else
      {:error, :product_not_ready} -> :error
    end
  end

  @impl Phoenix.Socket
  def id(_socket), do: "allbert_pack_readiness"
end
