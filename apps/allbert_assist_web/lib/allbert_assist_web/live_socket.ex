defmodule AllbertAssistWeb.LiveSocket do
  @moduledoc false

  use Phoenix.LiveView.Socket

  @impl Phoenix.Socket
  def connect(params, socket, connect_info) do
    with {:ok, epoch} <- AllbertAssistWeb.PackReadiness.admit(),
         {:ok, socket} <- super(params, socket, connect_info) do
      info = Map.put(connect_info, :allbert_pack_epoch, epoch)
      {:ok, put_in(socket.private[:connect_info], info)}
    else
      {:error, :product_not_ready} -> :error
      :error -> :error
    end
  end

  @impl Phoenix.Socket
  def id(_socket), do: "allbert_pack_readiness"
end
