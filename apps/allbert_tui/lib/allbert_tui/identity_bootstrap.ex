defmodule AllbertTUI.IdentityBootstrap do
  @moduledoc """
  Bounded Settings bootstrap for explicit local interactive TUI launchers.

  This module persists raw-absent channel activation and, for the default
  profile, the ordinary identity-map entry before Adapter startup. It is not
  called by the Adapter and provides no identity-resolution fallback.
  """

  alias AllbertAssist.Settings.Store

  @context %{
    actor: "first-run-local-tui-bootstrap",
    channel: "tui",
    provider: "terminal",
    provider_class: :local
  }

  @spec prepare_local_launch(String.t()) :: {:ok, map()} | {:error, term()}
  def prepare_local_launch(profile \\ "default") when is_binary(profile) do
    Store.prepare_local_tui_launch(Map.put(@context, :profile, profile))
  end
end
