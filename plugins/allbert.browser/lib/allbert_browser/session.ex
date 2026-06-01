defmodule AllbertBrowser.Session do
  @moduledoc """
  Browser session process.

  Plain GenServer is used because this process owns local driver state and has
  no Jido skill/composition lifecycle needs.
  """

  use GenServer

  alias AllbertAssist.Settings
  alias AllbertBrowser.Driver

  defstruct [
    :id,
    :driver_state,
    :created_at,
    :last_activity_at,
    :last_url,
    :idle_timer,
    :idle_timer_ref,
    :lifetime_timer
  ]

  def start_session(opts \\ []) do
    session_id = Keyword.get(opts, :session_id) || "session-#{System.unique_integer([:positive])}"

    spec = {__MODULE__, Keyword.put(opts, :session_id, session_id)}

    case DynamicSupervisor.start_child(AllbertBrowser.SessionSupervisor, spec) do
      {:ok, _pid} -> {:ok, session_id}
      {:error, {:already_started, _pid}} -> {:ok, session_id}
      {:error, reason} -> {:error, reason}
    end
  end

  def navigate(session_id, url, opts \\ []), do: call(session_id, {:navigate, url, opts})
  def click(session_id, selector, opts \\ []), do: call(session_id, {:click, selector, opts})
  def fill(session_id, selector, opts \\ []), do: call(session_id, {:fill, selector, opts})
  def download(session_id, url, opts \\ []), do: call(session_id, {:download, url, opts})
  def extract(session_id, format, opts \\ []), do: call(session_id, {:extract, format, opts})
  def screenshot(session_id, opts \\ []), do: call(session_id, {:screenshot, opts})
  def close(session_id), do: call(session_id, :close)

  def list do
    Registry.select(AllbertBrowser.Session.Registry, [
      {{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}
    ])
    |> Enum.flat_map(fn {id, pid} ->
      if Process.alive?(pid) do
        try do
          [GenServer.call(pid, :summary) |> Map.put(:session_id, id)]
        catch
          :exit, _reason -> []
        end
      else
        []
      end
    end)
  end

  def child_spec(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    %{
      id: {__MODULE__, session_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    with {:ok, driver_state} <- Driver.start_session(opts) do
      now = DateTime.utc_now()
      {idle_timer, idle_timer_ref} = schedule_idle_timeout()

      {:ok,
       %__MODULE__{
         id: session_id,
         driver_state: driver_state,
         created_at: now,
         last_activity_at: now,
         idle_timer: idle_timer,
         idle_timer_ref: idle_timer_ref,
         lifetime_timer: schedule_lifetime_timeout()
       }}
    end
  end

  @impl true
  def handle_call({:navigate, url, opts}, _from, state) do
    case Driver.navigate(state.driver_state, url, opts) do
      {:ok, %{state: driver_state, page_meta: page_meta}} ->
        {:reply, {:ok, page_meta},
         state
         |> Map.put(:driver_state, driver_state)
         |> Map.put(:last_url, url)
         |> mark_activity()}

      {:ok, page_meta} ->
        {:reply, {:ok, page_meta}, state |> Map.put(:last_url, url) |> mark_activity()}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:extract, format, opts}, _from, state) do
    case Driver.extract(state.driver_state, format, opts) do
      {:ok, extraction} -> {:reply, {:ok, extraction}, mark_activity(state)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:click, selector, opts}, _from, state) do
    case Driver.click(state.driver_state, selector, opts) do
      {:ok, %{state: driver_state, click: click}} ->
        {:reply, {:ok, click}, state |> Map.put(:driver_state, driver_state) |> mark_activity()}

      {:ok, click} ->
        {:reply, {:ok, click}, mark_activity(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:fill, selector, opts}, _from, state) do
    case Driver.fill(state.driver_state, selector, opts) do
      {:ok, %{state: driver_state, fill: fill}} ->
        {:reply, {:ok, fill}, state |> Map.put(:driver_state, driver_state) |> mark_activity()}

      {:ok, fill} ->
        {:reply, {:ok, fill}, mark_activity(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:download, url, opts}, _from, state) do
    case Driver.download(state.driver_state, url, opts) do
      {:ok, %{state: driver_state, download: download}} ->
        {:reply, {:ok, download}, state |> Map.put(:driver_state, driver_state) |> mark_activity()}

      {:ok, download} ->
        {:reply, {:ok, download}, mark_activity(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:screenshot, opts}, _from, state) do
    case Driver.screenshot(state.driver_state, opts) do
      {:ok, %{state: driver_state} = result} ->
        {:reply, {:ok, Map.delete(result, :state)},
         state |> Map.put(:driver_state, driver_state) |> mark_activity()}

      {:ok, result} ->
        {:reply, {:ok, result}, mark_activity(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:close, _from, state) do
    _ = Driver.close(state.driver_state)
    {:stop, :normal, :ok, state}
  end

  def handle_call(:summary, _from, state) do
    {:reply,
     %{
       created_at: state.created_at,
       last_activity_at: state.last_activity_at,
       last_url: state.last_url
     }, state}
  end

  @impl true
  def handle_info(:max_lifetime_timeout, state) do
    _ = Driver.close(state.driver_state)
    {:stop, :normal, state}
  end

  def handle_info({:idle_timeout, ref}, %{idle_timer_ref: ref} = state) do
    _ = Driver.close(state.driver_state)
    {:stop, :normal, state}
  end

  def handle_info({:idle_timeout, _ref}, state), do: {:noreply, state}

  defp call(session_id, message) do
    case Registry.lookup(AllbertBrowser.Session.Registry, session_id) do
      [{pid, _value}] -> GenServer.call(pid, message)
      [] -> {:error, :session_not_found}
    end
  end

  defp via(session_id), do: {:via, Registry, {AllbertBrowser.Session.Registry, session_id}}

  defp mark_activity(state) do
    cancel_timer(state.idle_timer)
    {idle_timer, idle_timer_ref} = schedule_idle_timeout()

    %{state | last_activity_at: DateTime.utc_now(), idle_timer: idle_timer, idle_timer_ref: idle_timer_ref}
  end

  defp schedule_lifetime_timeout do
    Process.send_after(self(), :max_lifetime_timeout, setting("browser.session.max_lifetime_ms", 300_000))
  end

  defp schedule_idle_timeout do
    ref = make_ref()
    timer = Process.send_after(self(), {:idle_timeout, ref}, setting("browser.session.idle_timeout_ms", 60_000))
    {timer, ref}
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    _ = Process.cancel_timer(timer)
    :ok
  end

  defp setting(key, fallback) do
    case Settings.get(key) do
      {:ok, value} -> value
      {:error, _reason} -> fallback
    end
  end
end
