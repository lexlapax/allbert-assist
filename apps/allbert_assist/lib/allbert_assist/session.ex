defmodule AllbertAssist.Session do
  @moduledoc """
  Public boundary for volatile local session scratchpad state.

  The scratchpad is keyed by `{user_id, session_id}` and is intentionally
  weaker than durable memory or conversation history. Callers use this module
  rather than touching ETS or the scratchpad GenServer directly.
  """

  alias AllbertAssist.Session.Scratchpad

  @max_session_id_length 128
  @max_working_memory_bytes 65_536
  @max_metadata_bytes 16_384

  @type entry :: %{
          user_id: String.t(),
          session_id: String.t(),
          active_app: atom() | nil,
          working_memory: map(),
          metadata: map(),
          inserted_at_ms: integer(),
          updated_at_ms: integer(),
          expires_at_ms: integer()
        }

  @doc "Return the maximum accepted `session_id` length."
  @spec max_session_id_length() :: pos_integer()
  def max_session_id_length, do: @max_session_id_length

  @doc "Fetch one unexpired session entry."
  @spec get(term(), term(), keyword()) :: {:ok, entry()} | {:error, term()}
  def get(user_id, session_id, opts \\ []) do
    with {:ok, key} <- key(user_id, session_id) do
      Scratchpad.call(server(opts), {:get, key, Keyword.get(opts, :touch?, false)})
    end
  end

  @doc "Create or replace selected fields on a session entry."
  @spec put(term(), term(), map(), keyword()) :: {:ok, entry()} | {:error, term()}
  def put(user_id, session_id, attrs, opts \\ [])

  def put(user_id, session_id, attrs, opts) when is_map(attrs) do
    with {:ok, key} <- key(user_id, session_id),
         {:ok, attrs} <- normalize_attrs(attrs) do
      Scratchpad.call(server(opts), {:put, key, attrs})
    end
  end

  def put(_user_id, _session_id, _attrs, _opts), do: {:error, :invalid_entry_attrs}

  @doc "Create or update the active app for a session."
  @spec set_active_app(term(), term(), atom() | nil, keyword()) ::
          {:ok, entry()} | {:error, term()}
  def set_active_app(user_id, session_id, active_app, opts \\ []) do
    with {:ok, key} <- key(user_id, session_id),
         {:ok, active_app} <- normalize_active_app(active_app) do
      Scratchpad.call(server(opts), {:set_active_app, key, active_app})
    end
  end

  @doc "Clear active app for an existing session entry."
  @spec clear_active_app(term(), term(), keyword()) :: {:ok, entry()} | {:error, term()}
  def clear_active_app(user_id, session_id, opts \\ []) do
    with {:ok, key} <- key(user_id, session_id) do
      Scratchpad.call(server(opts), {:clear_active_app, key})
    end
  end

  @doc "Shallow-merge transient working memory into the session entry."
  @spec merge_working_memory(term(), term(), map(), keyword()) ::
          {:ok, entry()} | {:error, term()}
  def merge_working_memory(user_id, session_id, working_memory, opts \\ []) do
    with {:ok, key} <- key(user_id, session_id),
         {:ok, working_memory} <- normalize_working_memory(working_memory) do
      Scratchpad.call(server(opts), {:merge_working_memory, key, working_memory})
    end
  end

  @doc "Delete one session entry."
  @spec clear(term(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def clear(user_id, session_id, opts \\ []) do
    with {:ok, key} <- key(user_id, session_id) do
      Scratchpad.call(server(opts), {:clear, key})
    end
  end

  @doc "List unexpired entries for one user."
  @spec list(term(), keyword()) :: {:ok, [entry()]} | {:error, term()}
  def list(user_id, opts \\ []) do
    with {:ok, user_id} <- normalize_user_id(user_id) do
      Scratchpad.call(server(opts), {:list, user_id})
    end
  end

  @doc "Extend the TTL of an existing session entry."
  @spec touch(term(), term(), keyword()) :: {:ok, entry()} | {:error, term()}
  def touch(user_id, session_id, opts \\ []) do
    with {:ok, key} <- key(user_id, session_id) do
      Scratchpad.call(server(opts), {:touch, key})
    end
  end

  @doc "Remove expired entries from the scratchpad."
  @spec sweep_expired(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sweep_expired(opts \\ []) do
    Scratchpad.call(server(opts), :sweep_expired)
  end

  @doc "Return a trace-safe summary of an entry."
  @spec summary(entry()) :: map()
  def summary(%{} = entry) do
    %{
      user_id: entry.user_id,
      session_id: entry.session_id,
      active_app: entry.active_app,
      remaining_ttl_ms: remaining_ttl_ms(entry),
      metadata_keys: metadata_keys(entry),
      working_memory_keys: working_memory_keys(entry),
      working_memory_key_count: map_size(Map.get(entry, :working_memory, %{}))
    }
  end

  @doc "Return a stable string label for an active app."
  @spec active_app_label(atom() | nil) :: String.t()
  def active_app_label(nil), do: "none"
  def active_app_label(active_app) when is_atom(active_app), do: Atom.to_string(active_app)

  @doc "Return sorted working-memory keys without values."
  @spec working_memory_keys(entry()) :: [String.t()]
  def working_memory_keys(%{} = entry) do
    entry
    |> Map.get(:working_memory, %{})
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  @doc "Return sorted metadata keys without values."
  @spec metadata_keys(entry()) :: [String.t()]
  def metadata_keys(%{} = entry) do
    entry
    |> Map.get(:metadata, %{})
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  @doc "Return remaining TTL from monotonic time."
  @spec remaining_ttl_ms(entry()) :: non_neg_integer()
  def remaining_ttl_ms(%{} = entry) do
    max(entry.expires_at_ms - monotonic_ms(), 0)
  end

  @doc false
  def normalize_user_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_user_id}
      user_id -> {:ok, user_id}
    end
  end

  def normalize_user_id(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_user_id()

  def normalize_user_id(_value), do: {:error, :invalid_user_id}

  @doc false
  def normalize_session_id(value) when is_binary(value) do
    session_id = String.trim(value)

    cond do
      session_id == "" -> {:error, :invalid_session_id}
      String.length(session_id) > @max_session_id_length -> {:error, :session_id_too_long}
      true -> {:ok, session_id}
    end
  end

  def normalize_session_id(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_session_id()

  def normalize_session_id(_value), do: {:error, :invalid_session_id}

  defp key(user_id, session_id) do
    with {:ok, user_id} <- normalize_user_id(user_id),
         {:ok, session_id} <- normalize_session_id(session_id) do
      {:ok, {user_id, session_id}}
    end
  end

  defp normalize_attrs(attrs) do
    with {:ok, active_app} <- normalize_optional_active_app(attrs),
         {:ok, working_memory} <- normalize_optional_map(attrs, :working_memory, :working_memory),
         {:ok, metadata} <- normalize_optional_map(attrs, :metadata, :metadata) do
      {:ok,
       %{}
       |> maybe_put(:active_app, active_app)
       |> maybe_put(:working_memory, working_memory)
       |> maybe_put(:metadata, metadata)}
    end
  end

  defp normalize_optional_active_app(attrs) do
    if has_key?(attrs, :active_app) do
      attrs |> value(:active_app) |> normalize_active_app()
    else
      {:ok, :__absent__}
    end
  end

  defp normalize_active_app(nil), do: {:ok, nil}
  defp normalize_active_app(active_app) when is_atom(active_app), do: {:ok, active_app}
  defp normalize_active_app(_active_app), do: {:error, :invalid_active_app}

  defp normalize_optional_map(attrs, key, kind) do
    if has_key?(attrs, key) do
      attrs
      |> value(key)
      |> normalize_bounded_map(kind)
    else
      {:ok, :__absent__}
    end
  end

  defp normalize_working_memory(value), do: normalize_bounded_map(value, :working_memory)

  defp normalize_bounded_map(value, :working_memory) when is_map(value) do
    cond do
      Enum.any?(Map.keys(value), &reserved_working_memory_key?/1) ->
        {:error, :reserved_key}

      Enum.any?(Map.keys(value), &sensitive_key?/1) ->
        {:error, :sensitive_working_memory_key}

      :erlang.external_size(value) > @max_working_memory_bytes ->
        {:error, :working_memory_too_large}

      true ->
        {:ok, value}
    end
  end

  defp normalize_bounded_map(value, :metadata) when is_map(value) do
    cond do
      Enum.any?(Map.keys(value), &sensitive_key?/1) ->
        {:error, :sensitive_metadata_key}

      :erlang.external_size(value) > @max_metadata_bytes ->
        {:error, :metadata_too_large}

      true ->
        {:ok, value}
    end
  end

  defp normalize_bounded_map(_value, :working_memory), do: {:error, :invalid_working_memory}
  defp normalize_bounded_map(_value, :metadata), do: {:error, :invalid_metadata}

  defp has_key?(attrs, key),
    do: Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key))

  defp value(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp maybe_put(map, _key, :__absent__), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp reserved_working_memory_key?(key), do: to_string(key) == "canvas_tiles"

  defp sensitive_key?(key) do
    key
    |> to_string()
    |> String.downcase()
    |> then(&String.contains?(&1, ["secret", "token", "password", "api_key", "credential"]))
  end

  defp server(opts), do: Keyword.get(opts, :server, Keyword.get(opts, :name, Scratchpad))
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
