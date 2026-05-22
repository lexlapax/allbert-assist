defmodule StockSageWeb.Live do
  @moduledoc false

  alias AllbertAssist.{Session, Settings}

  @user_id "local"
  @session_id "web-local"

  def assign_context(socket, surface_id) do
    _ = Session.set_active_app(@user_id, @session_id, :stocksage)

    socket
    |> Phoenix.Component.assign(:active_app, :stocksage)
    |> Phoenix.Component.assign(:session_id, @session_id)
    |> Phoenix.Component.assign(:stocksage_surface, surface_id)
    |> Phoenix.Component.assign(:user_id, @user_id)
    |> Phoenix.Component.assign(:web_enabled?, web_enabled?())
  end

  def web_enabled? do
    case Settings.get("stocksage.web.enabled") do
      {:ok, enabled?} when is_boolean(enabled?) -> enabled?
      _error -> true
    end
  end
end
