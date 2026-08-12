defmodule AllbertArtifactsWeb.Live do
  @moduledoc false

  alias AllbertAssist.Session

  @user_id "local"
  @session_id "web-local"

  def assign_context(socket, surface_id) do
    _ = Session.set_active_app(@user_id, @session_id, :allbert_artifacts)

    socket
    |> Phoenix.Component.assign(:active_app, :allbert_artifacts)
    |> Phoenix.Component.assign(:session_id, @session_id)
    |> Phoenix.Component.assign(:surface_id, surface_id)
    |> Phoenix.Component.assign(:user_id, @user_id)
  end
end
