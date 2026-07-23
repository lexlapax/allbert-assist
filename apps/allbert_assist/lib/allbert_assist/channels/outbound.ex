defmodule AllbertAssist.Channels.Outbound do
  @moduledoc """
  v0.54 M10 (ADR 0063) — the single boundary for sending an **operator-initiated**
  outbound message to a channel. `send_channel_message` calls only this; it never
  touches a provider client directly.

  Resolves the channel's adapter module (from its registered descriptor) and
  dispatches to the adapter's `deliver_outbound/3` callback. Adapters that have not
  implemented outbound compose return `{:error, :outbound_not_implemented}` — a
  clear, non-silent degradation (surfaced to the operator), never a crash.

  Identity-allowlist + trust-class gating is enforced by the **action** before this
  boundary is reached (ADR 0016/0056/0059); this module only performs the dispatch.
  """
  alias AllbertAssist.Channels

  @doc """
  Send `body` to `target` on `channel`. `opts` may carry adapter-specific hints
  (e.g. `:thread`). Returns `{:ok, receipt}` | `{:error, reason}`.
  """
  @callback deliver_outbound(target :: String.t(), body :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @spec send(String.t(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def send(channel, target, body, opts \\ [])
      when is_binary(channel) and is_binary(target) and is_binary(body) do
    with true <-
           Channels.channel_live_use_allowed?(channel) ||
             {:error, Channels.channel_live_use_error(channel)},
         {:ok, module} <- adapter_module(channel),
         true <-
           function_exported?(module, :deliver_outbound, 3) || {:error, :outbound_not_implemented} do
      module.deliver_outbound(target, body, opts)
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :outbound_not_implemented}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp adapter_module(channel) do
    case Channels.channel_descriptor(channel) do
      {:ok, %{adapter: module}} when is_atom(module) -> {:ok, module}
      {:ok, %{child_spec: {module, _opts}}} when is_atom(module) -> {:ok, module}
      {:ok, _descriptor} -> {:error, :no_adapter_module}
      {:error, reason} -> {:error, reason}
    end
  end
end
