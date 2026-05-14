defmodule AllbertAssist.Channels.Telegram.Renderer do
  @moduledoc false

  def render_response(_runtime_response, _opts \\ []), do: {:error, :not_implemented}
  def render_approval_handoff(_handoff_data, _opts \\ []), do: {:error, :not_implemented}
end
