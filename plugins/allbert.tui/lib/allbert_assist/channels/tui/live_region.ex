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
          required(:max_text_bytes) => pos_integer(),
          optional(:mode) => :owl | :output,
          optional(:output_fun) => (String.t() -> term()),
          optional(:last_tool_names) => [String.t()],
          optional(:last_result_count) => non_neg_integer(),
          optional(:last_assistant_bytes) => non_neg_integer(),
          optional(:complete_emitted?) => boolean(),
          optional(:cancelled_emitted?) => boolean()
        }

  @assistant_progress_interval_bytes 256

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
      mode: :owl,
      max_text_bytes: max_text_bytes
    }

    with :ok <- add_block(live_region),
         :ok <- update_block(live_region) do
      {:ok, live_region}
    end
  end

  @doc "Create a transcript-stable progress region backed by ordinary output lines."
  @spec start_output((String.t() -> term()), String.t(), keyword()) :: {:ok, t()}
  def start_output(output_fun, turn_id, opts \\ [])
      when is_function(output_fun, 1) and is_binary(turn_id) and turn_id != "" do
    {:ok,
     %{
       screen: nil,
       screen_module: nil,
       block_id: @default_block_id,
       renderer_state: StreamRenderer.new(turn_id),
       active?: true,
       mode: :output,
       max_text_bytes: Keyword.get(opts, :max_text_bytes, 12_000),
       output_fun: output_fun,
       last_tool_names: [],
       last_result_count: 0,
       last_assistant_bytes: 0,
       complete_emitted?: false,
       cancelled_emitted?: false
     }}
  end

  @doc "Apply one stream event and update the live block."
  @spec apply_event(t(), map()) :: {:ok, t()} | {:error, term()}
  def apply_event(%{mode: :output, active?: true} = live_region, event) do
    with {:ok, renderer_state} <- StreamRenderer.apply_event(live_region.renderer_state, event) do
      live_region = %{live_region | renderer_state: renderer_state}
      {:ok, maybe_emit_output_progress(live_region)}
    end
  end

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

  def clear(%{mode: :output} = live_region), do: {:ok, %{live_region | active?: false}}

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

    with :ok <-
           screen_call(live_region, :update, [
             live_region.screen,
             live_region.block_id,
             rendered
           ]) do
      screen_call(live_region, :await_render, [live_region.screen])
    end
  end

  defp maybe_emit_output_progress(live_region) do
    live_region
    |> maybe_emit_tool_progress()
    |> maybe_emit_result_progress()
    |> maybe_emit_assistant_progress()
    |> maybe_emit_cancelled_progress()
    |> maybe_emit_complete_progress()
  end

  defp maybe_emit_tool_progress(%{renderer_state: %{tool_calls: tool_calls}} = live_region) do
    names = tool_names(tool_calls)

    if names != [] and names != Map.get(live_region, :last_tool_names, []) do
      live_region
      |> emit_progress("Tool calls: #{Enum.join(names, ", ")}")
      |> Map.put(:last_tool_names, names)
    else
      live_region
    end
  end

  defp maybe_emit_result_progress(%{renderer_state: %{tool_results: results}} = live_region) do
    count = length(results)

    if count > 0 and count != Map.get(live_region, :last_result_count, 0) do
      live_region
      |> emit_progress("Tool results: #{count} received")
      |> Map.put(:last_result_count, count)
    else
      live_region
    end
  end

  defp maybe_emit_assistant_progress(%{renderer_state: %{assistant_text: text}} = live_region) do
    bytes = byte_size(text)
    last_bytes = Map.get(live_region, :last_assistant_bytes, 0)

    cond do
      bytes == 0 ->
        live_region

      last_bytes == 0 or bytes - last_bytes >= @assistant_progress_interval_bytes ->
        live_region
        |> emit_progress("Assistant streaming (#{bytes} bytes)")
        |> Map.put(:last_assistant_bytes, bytes)

      true ->
        live_region
    end
  end

  defp maybe_emit_cancelled_progress(%{renderer_state: %{cancelled?: true}} = live_region) do
    if Map.get(live_region, :cancelled_emitted?, false) do
      live_region
    else
      live_region
      |> emit_progress("Turn cancelled")
      |> Map.put(:cancelled_emitted?, true)
    end
  end

  defp maybe_emit_cancelled_progress(live_region), do: live_region

  defp maybe_emit_complete_progress(%{renderer_state: %{complete?: true}} = live_region) do
    if Map.get(live_region, :complete_emitted?, false) do
      live_region
    else
      live_region
      |> emit_progress("Turn complete")
      |> Map.put(:complete_emitted?, true)
    end
  end

  defp maybe_emit_complete_progress(live_region), do: live_region

  defp emit_progress(live_region, line) do
    live_region.output_fun.(line)
    live_region
  end

  defp tool_names(tool_calls) do
    tool_calls
    |> Enum.sort_by(fn {id, _tool} -> id end)
    |> Enum.map(fn {_id, tool} -> Map.get(tool, :name) || "tool" end)
    |> Enum.uniq()
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
