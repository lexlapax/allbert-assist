defmodule AllbertBrowser.Session do
  @moduledoc """
  Browser session process.

  Plain GenServer is used because this process owns local driver state and has
  no Jido skill/composition lifecycle needs.
  """

  use GenServer

  alias AllbertBrowser.Driver

  defstruct [:id, :driver_state, :created_at, :last_url]

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
  def extract(session_id, format, opts \\ []), do: call(session_id, {:extract, format, opts})
  def screenshot(session_id, opts \\ []), do: call(session_id, {:screenshot, opts})
  def close(session_id), do: call(session_id, :close)

  def list do
    Registry.select(AllbertBrowser.Session.Registry, [
      {{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}
    ])
    |> Enum.map(fn {id, pid} -> GenServer.call(pid, :summary) |> Map.put(:session_id, id) end)
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
      {:ok,
       %__MODULE__{
         id: session_id,
         driver_state: driver_state,
         created_at: DateTime.utc_now()
       }}
    end
  end

  @impl true
  def handle_call({:navigate, url, opts}, _from, state) do
    case Driver.navigate(state.driver_state, url, opts) do
      {:ok, %{state: driver_state, page_meta: page_meta}} ->
        {:reply, {:ok, page_meta}, %{state | driver_state: driver_state, last_url: url}}

      {:ok, page_meta} ->
        {:reply, {:ok, page_meta}, %{state | last_url: url}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:extract, format, opts}, _from, state) do
    {:reply, Driver.extract(state.driver_state, format, opts), state}
  end

  def handle_call({:click, selector, opts}, _from, state) do
    case Driver.click(state.driver_state, selector, opts) do
      {:ok, %{state: driver_state, click: click}} ->
        {:reply, {:ok, click}, %{state | driver_state: driver_state}}

      {:ok, click} ->
        {:reply, {:ok, click}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:screenshot, opts}, _from, state) do
    case Driver.screenshot(state.driver_state, opts) do
      {:ok, %{state: driver_state} = result} ->
        {:reply, {:ok, Map.delete(result, :state)}, %{state | driver_state: driver_state}}

      other ->
        {:reply, other, state}
    end
  end

  def handle_call(:close, _from, state) do
    _ = Driver.close(state.driver_state)
    {:stop, :normal, :ok, state}
  end

  def handle_call(:summary, _from, state) do
    {:reply, %{created_at: state.created_at, last_url: state.last_url}, state}
  end

  defp call(session_id, message) do
    case Registry.lookup(AllbertBrowser.Session.Registry, session_id) do
      [{pid, _value}] -> GenServer.call(pid, message)
      [] -> {:error, :session_not_found}
    end
  end

  defp via(session_id), do: {:via, Registry, {AllbertBrowser.Session.Registry, session_id}}
end
