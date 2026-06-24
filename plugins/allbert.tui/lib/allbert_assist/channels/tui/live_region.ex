defmodule AllbertAssist.Channels.TUI.LiveRegion do
  @moduledoc false

  require Logger

  alias AllbertAssist.Channels.TUI.Renderer
  alias AllbertAssist.Coding.StreamRenderer
  alias AllbertAssist.Runtime.Redactor

  @default_block_id :allbert_coding_stream

  @type t :: %{
          required(:screen) => term(),
          required(:screen_module) => module(),
          required(:block_id) => atom(),
          required(:renderer_state) => StreamRenderer.t(),
          required(:active?) => boolean(),
          required(:max_text_bytes) => pos_integer()
        }

  @doc "Create the coding live-region block and render the empty stream state."
  @spec start(term(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(screen, turn_id, opts \\ []) when is_binary(turn_id) do
    screen_module = Keyword.get(opts, :screen_module, Owl.LiveScreen)
    block_id = Keyword.get(opts, :block_id, @default_block_id)
    max_text_bytes = Keyword.get(opts, :max_text_bytes, 12_000)
    renderer_state = StreamRenderer.new(turn_id)

    live_region = %{
      screen: screen,
      screen_module: screen_module,
      block_id: block_id,
      renderer_state: renderer_state,
      active?: true,
      max_text_bytes: max_text_bytes
    }

    with :ok <- add_block(live_region),
         :ok <- update_block(live_region) do
      {:ok, live_region}
    end
  end

  @doc "Apply one stream event and update the live block."
  @spec apply_event(t(), map()) :: {:ok, t()} | {:error, term()}
  def apply_event(%{active?: true} = live_region, event) do
    with {:ok, renderer_state} <- StreamRenderer.apply_event(live_region.renderer_state, event) do
      live_region = %{live_region | renderer_state: renderer_state}

      with :ok <- update_block(live_region) do
        {:ok, live_region}
      end
    end
  end

  def apply_event(%{active?: false} = live_region, _event), do: {:ok, live_region}

  @doc "Clear and flush the live-region block."
  @spec clear(t()) :: {:ok, t()} | {:error, term()}
  def clear(%{active?: false} = live_region), do: {:ok, live_region}

  def clear(live_region) do
    with :ok <- screen_call(live_region, :update, [live_region.screen, live_region.block_id, []]),
         :ok <- screen_call(live_region, :await_render, [live_region.screen]),
         :ok <- screen_call(live_region, :flush, [live_region.screen]) do
      {:ok, %{live_region | active?: false}}
    end
  end

  defp add_block(live_region) do
    screen_call(live_region, :add_block, [
      live_region.screen,
      live_region.block_id,
      [state: [], render: &Function.identity/1]
    ])
  end

  defp update_block(live_region) do
    rendered =
      Renderer.stream_state(live_region.renderer_state,
        max_text_bytes: live_region.max_text_bytes
      )

    with :ok <- screen_call(live_region, :update, [
           live_region.screen,
           live_region.block_id,
           rendered
         ]) do
      screen_call(live_region, :await_render, [live_region.screen])
    end
  end

  defp screen_call(%{screen_module: module}, function, args) do
    apply(module, function, args)
    :ok
  rescue
    error ->
      reason = Exception.message(error)
      Logger.debug("tui coding live region unavailable: #{reason}")
      {:error, reason}
  catch
    :exit, reason ->
      Logger.debug("tui coding live region unavailable: #{inspect(Redactor.redact(reason))}")
      {:error, reason}
  end
end
