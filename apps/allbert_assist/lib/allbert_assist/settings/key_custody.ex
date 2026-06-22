defmodule AllbertAssist.Settings.KeyCustody do
  @moduledoc """
  Decrypt-once custody process for Settings Central secrets.

  This is a plain GenServer because it owns one local cache and exposes no
  Allbert capability action. Secret values are held behind zero-arity closures;
  local VM callers can fetch values through this module, while process state and
  status rendering avoid containing directly inspectable secret material.
  """

  use GenServer

  alias AllbertAssist.Settings.Audit
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Settings.Store

  defmodule State do
    @moduledoc false

    defstruct root: nil,
              secrets_path: nil,
              secrets: %{},
              loaded?: false,
              load_error: nil
  end

  defimpl Inspect, for: State do
    import Inspect.Algebra

    alias AllbertAssist.Settings.KeyCustody

    def inspect(state, opts) do
      state
      |> KeyCustody.redacted_state()
      |> to_doc(opts)
      |> concat_prefix()
    end

    defp concat_prefix(doc) do
      concat(["#AllbertAssist.Settings.KeyCustody.State<", doc, ">"])
    end
  end

  @type secret_ref :: String.t()
  @type fetch_context :: map()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec fetch(secret_ref(), fetch_context()) :: {:ok, String.t()} | {:error, term()}
  def fetch(secret_ref, context \\ %{}) do
    with :ok <- Secrets.validate_secret_ref(secret_ref),
         {:ok, value} <- call_custody({:fetch, secret_ref, context}) do
      {:ok, value}
    end
  end

  @spec status(secret_ref()) :: :configured | :missing | :decrypt_failed | :invalid_ref
  def status(secret_ref) do
    with :ok <- Secrets.validate_secret_ref(secret_ref) do
      case call_custody({:status, secret_ref}) do
        {:ok, status} -> status
        {:error, {:secret_decrypt_failed, _reason}} -> :decrypt_failed
        {:error, _reason} -> :missing
      end
    else
      {:error, _reason} -> :invalid_ref
    end
  end

  @spec list_secret_status(String.t() | nil) :: {:ok, [map()]} | {:decrypt_failed, term()}
  def list_secret_status(namespace \\ nil) do
    case call_custody({:list_status, namespace}) do
      {:ok, statuses} -> {:ok, statuses}
      {:error, {:secret_decrypt_failed, reason}} -> {:decrypt_failed, reason}
      {:error, reason} -> {:decrypt_failed, reason}
    end
  end

  @spec secure_compare(secret_ref(), binary(), fetch_context()) ::
          {:ok, boolean()} | {:error, term()}
  def secure_compare(secret_ref, candidate, context \\ %{})

  def secure_compare(secret_ref, candidate, context) when is_binary(candidate) do
    with {:ok, expected} <- fetch(secret_ref, context) do
      {:ok,
       byte_size(candidate) == byte_size(expected) and
         Plug.Crypto.secure_compare(candidate, expected)}
    end
  end

  def secure_compare(_secret_ref, _candidate, _context),
    do: {:error, {:invalid_secret_value, :not_a_binary}}

  @spec invalidate(secret_ref() | :all) :: :ok
  def invalidate(secret_ref_or_all \\ :all) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.cast(__MODULE__, {:invalidate, secret_ref_or_all})
    end
  end

  @doc false
  def redacted_state(%State{} = state) do
    %{
      root: state.root,
      secrets_path: state.secrets_path,
      secret_count: map_size(state.secrets),
      loaded?: state.loaded?,
      load_error: redacted_error(state.load_error)
    }
  end

  @impl true
  def init(_opts) do
    :erlang.process_flag(:sensitive, true)
    {:ok, %State{}}
  end

  @impl true
  def handle_call({:fetch, secret_ref, context}, _from, state) do
    with {:ok, state} <- ensure_loaded(state),
         {:ok, secret_fun} <- fetch_secret_fun(state, secret_ref),
         {:ok, value} <- reveal_secret(secret_fun) do
      audit_fetch(secret_ref, context)
      {:reply, {:ok, value}, state}
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:status, secret_ref}, _from, state) do
    with {:ok, state} <- ensure_loaded(state) do
      status = if Map.has_key?(state.secrets, secret_ref), do: :configured, else: :missing
      {:reply, {:ok, status}, state}
    else
      {:error, {:secret_decrypt_failed, reason}, state} ->
        {:reply, {:error, {:secret_decrypt_failed, reason}}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:list_status, namespace}, _from, state) do
    with {:ok, state} <- ensure_loaded(state) do
      statuses =
        state.secrets
        |> Map.keys()
        |> Enum.filter(fn ref -> is_nil(namespace) or String.starts_with?(ref, namespace) end)
        |> Enum.sort()
        |> Enum.map(&%{secret_ref: &1, status: :configured})

      {:reply, {:ok, statuses}, state}
    else
      {:error, {:secret_decrypt_failed, reason}, state} ->
        {:reply, {:error, {:secret_decrypt_failed, reason}}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:invalidate, :all}, state), do: {:noreply, unloaded_state(state)}

  def handle_cast({:invalidate, secret_ref}, state) when is_binary(secret_ref) do
    {:noreply, %{unloaded_state(state) | secrets: Map.delete(state.secrets, secret_ref)}}
  end

  @impl true
  def format_status(status) do
    Map.update(status, :state, :redacted, fn
      %State{} = state -> redacted_state(state)
      _other -> :redacted
    end)
  end

  defp call_custody(message) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :key_custody_unavailable}
      _pid -> GenServer.call(__MODULE__, message)
    end
  end

  defp ensure_loaded(%State{} = state) do
    {root, path} = location()

    if state.loaded? and state.root == root and state.secrets_path == path do
      {:ok, state}
    else
      load_state(%{state | root: root, secrets_path: path})
    end
  end

  defp load_state(%State{} = state) do
    case Secrets.load_plaintext_for_custody() do
      {:ok, plaintext} ->
        secrets =
          plaintext
          |> Secrets.plaintext_entries_for_custody()
          |> Map.new(fn {secret_ref, value} -> {secret_ref, secret_closure(value)} end)

        {:ok, %{state | secrets: secrets, loaded?: true, load_error: nil}}

      {:error, {:secret_decrypt_failed, reason}} ->
        state = %{
          state
          | secrets: %{},
            loaded?: false,
            load_error: {:secret_decrypt_failed, reason}
        }

        {:error, {:secret_decrypt_failed, reason}, state}

      {:error, reason} ->
        state = %{state | secrets: %{}, loaded?: false, load_error: reason}
        {:error, reason, state}
    end
  end

  defp fetch_secret_fun(%State{} = state, secret_ref) do
    case Map.fetch(state.secrets, secret_ref) do
      {:ok, secret_fun} -> {:ok, secret_fun}
      :error -> {:error, {:secret_not_found, secret_ref}}
    end
  end

  defp reveal_secret(secret_fun) when is_function(secret_fun, 0) do
    try do
      {:ok, secret_fun.()}
    rescue
      exception ->
        stacktrace = Plug.Crypto.prune_args_from_stacktrace(__STACKTRACE__)
        reraise exception, stacktrace
    end
  end

  defp secret_closure(value) when is_binary(value), do: fn -> value end

  defp audit_fetch(secret_ref, context) do
    case Audit.append_secret_fetch(secret_ref, context) do
      {:ok, _path} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp unloaded_state(%State{} = state) do
    %{state | secrets: %{}, loaded?: false, load_error: nil}
  end

  defp location do
    {Store.root(), Secrets.secrets_path()}
  end

  defp redacted_error(nil), do: nil
  defp redacted_error({kind, _reason}) when kind in [:secret_decrypt_failed], do: kind
  defp redacted_error(reason), do: reason
end
