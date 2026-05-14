defmodule AllbertAssist.Conversations do
  @moduledoc """
  SQLite conversation history for local workspace identity.

  Conversation rows are separate from markdown memory. They provide ordered,
  user-scoped turn history for runtime context and operator inspection.
  """

  import Ecto.Query

  alias AllbertAssist.Conversations.Message
  alias AllbertAssist.Conversations.Thread
  alias AllbertAssist.Repo

  @default_kind "general"
  @default_list_limit 20
  @default_context_limit 12

  @type thread_result :: {:ok, Thread.t()} | {:error, term()}

  @doc "Create a general conversation thread for a local string user id."
  @spec create_thread(map()) :: thread_result()
  def create_thread(attrs) when is_map(attrs) do
    now = utc_now()

    attrs =
      attrs
      |> atomize_known_keys([:id, :user_id, :title, :kind, :app_id, :last_message_at])
      |> Map.put_new(:id, new_id("thr"))
      |> Map.put_new(:kind, @default_kind)
      |> Map.put_new(:title, title_from_text(Map.get(attrs, :text) || Map.get(attrs, "text")))
      |> Map.put_new(:last_message_at, now)

    %Thread{}
    |> Thread.changeset(attrs)
    |> Repo.insert()
  end

  def create_thread(_attrs), do: {:error, :invalid_thread_attrs}

  @doc "Create a new general thread for `user_id` with a title derived from text."
  @spec create_general_thread(String.t(), String.t() | nil) :: thread_result()
  def create_general_thread(user_id, text \\ nil) do
    create_thread(%{
      user_id: user_id,
      title: title_from_text(text),
      kind: @default_kind,
      app_id: nil
    })
  end

  @doc "Fetch a thread only when it belongs to `user_id`."
  @spec get_thread(String.t(), String.t()) :: thread_result()
  def get_thread(user_id, thread_id) do
    user_id = normalize_string(user_id)
    thread_id = normalize_string(thread_id)

    query =
      from thread in Thread,
        where: thread.id == ^thread_id and thread.user_id == ^user_id

    case Repo.one(query) do
      %Thread{} = thread -> {:ok, thread}
      nil -> {:error, {:thread_not_found, thread_id}}
    end
  end

  @doc "Return the user's most recently updated general thread, if one exists."
  @spec recent_general_thread(String.t()) :: {:ok, Thread.t() | nil}
  def recent_general_thread(user_id) do
    user_id = normalize_string(user_id)

    query =
      from thread in Thread,
        where:
          thread.user_id == ^user_id and thread.kind == ^@default_kind and is_nil(thread.app_id),
        order_by: [
          desc: thread.last_message_at,
          desc: thread.updated_at,
          desc: thread.inserted_at
        ],
        limit: 1

    {:ok, Repo.one(query)}
  end

  @doc "Resolve a user-scoped thread by explicit id, recent thread, or new thread."
  @spec resolve_thread(map()) :: thread_result()
  def resolve_thread(attrs) when is_map(attrs) do
    user_id = normalize_string(field(attrs, :user_id) || "local")
    thread_id = normalize_optional_string(field(attrs, :thread_id))
    new_thread? = truthy?(field(attrs, :new_thread))
    text = field(attrs, :text)

    cond do
      new_thread? and present?(thread_id) ->
        {:error, :thread_conflict}

      new_thread? ->
        create_general_thread(user_id, text)

      present?(thread_id) ->
        get_thread(user_id, thread_id)

      true ->
        get_or_create_recent_general_thread(user_id, text)
    end
  end

  def resolve_thread(_attrs), do: {:error, :invalid_thread_attrs}

  @doc "List threads owned by a local string user id."
  @spec list_threads(String.t(), keyword()) :: [Thread.t()]
  def list_threads(user_id, opts \\ []) do
    limit = normalize_limit(Keyword.get(opts, :limit, @default_list_limit))
    user_id = normalize_string(user_id)

    query =
      from thread in Thread,
        where: thread.user_id == ^user_id,
        order_by: [
          desc: thread.last_message_at,
          desc: thread.updated_at,
          desc: thread.inserted_at
        ],
        limit: ^limit

    Repo.all(query)
  end

  @doc "Return a user-scoped thread and ordered messages."
  @spec show_thread(String.t(), String.t(), keyword()) ::
          {:ok, %{thread: Thread.t(), messages: [Message.t()]}} | {:error, term()}
  def show_thread(user_id, thread_id, opts \\ []) do
    with {:ok, thread} <- get_thread(user_id, thread_id) do
      {:ok, %{thread: thread, messages: list_messages(thread, opts)}}
    end
  end

  @doc "Count messages in a user-owned thread."
  @spec message_count(Thread.t()) :: non_neg_integer()
  def message_count(%Thread{} = thread) do
    query =
      from message in Message,
        where: message.thread_id == ^thread.id and message.user_id == ^thread.user_id

    Repo.aggregate(query, :count, :id)
  end

  @doc "Append a user-authored message to a thread."
  @spec append_user_message(Thread.t(), String.t(), map() | keyword()) ::
          {:ok, Message.t()} | {:error, term()}
  def append_user_message(%Thread{} = thread, content, attrs \\ %{}) do
    append_message(thread, Map.merge(to_attrs(attrs), %{role: "user", content: content}))
  end

  @doc "Append an assistant-authored message to a thread."
  @spec append_assistant_message(Thread.t(), String.t(), map() | keyword()) ::
          {:ok, Message.t()} | {:error, term()}
  def append_assistant_message(%Thread{} = thread, content, attrs \\ %{}) do
    append_message(thread, Map.merge(to_attrs(attrs), %{role: "assistant", content: content}))
  end

  @doc "Append one message and update the parent thread's last-message timestamp."
  @spec append_message(Thread.t(), map()) :: {:ok, Message.t()} | {:error, term()}
  def append_message(%Thread{} = thread, attrs) when is_map(attrs) do
    now = utc_now()

    attrs =
      attrs
      |> atomize_known_keys([
        :id,
        :role,
        :content,
        :action_log,
        :trace_id,
        :input_signal_id,
        :response_signal_id,
        :metadata
      ])
      |> Map.put_new(:id, new_id("msg"))
      |> Map.put(:thread_id, thread.id)
      |> Map.put(:user_id, thread.user_id)
      |> Map.put_new(:action_log, %{})
      |> Map.put_new(:metadata, %{})

    case Repo.transaction(fn -> insert_message_and_touch_thread(thread, attrs, now) end) do
      {:ok, message} -> {:ok, message}
      {:error, reason} -> {:error, reason}
    end
  end

  def append_message(_thread, _attrs), do: {:error, :invalid_message_attrs}

  @doc "List messages in chronological order for a thread."
  @spec list_messages(Thread.t(), keyword()) :: [Message.t()]
  def list_messages(%Thread{} = thread, opts \\ []) do
    limit = normalize_limit(Keyword.get(opts, :limit, @default_list_limit))

    query =
      from message in Message,
        where: message.thread_id == ^thread.id and message.user_id == ^thread.user_id,
        order_by: [asc: message.inserted_at, asc: message.id],
        limit: ^limit

    Repo.all(query)
  end

  @doc "Load bounded recent messages in chronological order for agent context."
  @spec recent_context(Thread.t(), keyword()) :: [map()]
  def recent_context(%Thread{} = thread, opts \\ []) do
    limit = normalize_limit(Keyword.get(opts, :limit, @default_context_limit))
    exclude_id = Keyword.get(opts, :exclude_message_id)

    base =
      from message in Message,
        where: message.thread_id == ^thread.id and message.user_id == ^thread.user_id

    base
    |> maybe_exclude_message(exclude_id)
    |> order_by([message], desc: message.inserted_at, desc: message.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.map(&context_message/1)
  end

  @doc "Return a concise title derived from a user message."
  @spec title_from_text(String.t() | nil) :: String.t()
  def title_from_text(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> "New conversation"
      title -> String.slice(title, 0, 80)
    end
  end

  def title_from_text(_text), do: "New conversation"

  defp get_or_create_recent_general_thread(user_id, text) do
    case recent_general_thread(user_id) do
      {:ok, %Thread{} = thread} -> {:ok, thread}
      {:ok, nil} -> create_general_thread(user_id, text)
    end
  end

  defp insert_message_and_touch_thread(thread, attrs, timestamp) do
    with {:ok, message} <- Repo.insert(Message.changeset(%Message{}, attrs)),
         {:ok, _thread} <- Repo.update(Thread.last_message_changeset(thread, timestamp)) do
      message
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp to_attrs(attrs) when is_map(attrs), do: attrs
  defp to_attrs(attrs) when is_list(attrs), do: Map.new(attrs)
  defp to_attrs(_attrs), do: %{}

  defp maybe_exclude_message(query, nil), do: query
  defp maybe_exclude_message(query, ""), do: query

  defp maybe_exclude_message(query, message_id) do
    from message in query, where: message.id != ^message_id
  end

  defp context_message(%Message{} = message) do
    %{
      role: message.role,
      content: message.content,
      inserted_at: DateTime.to_iso8601(message.inserted_at),
      trace_id: message.trace_id
    }
  end

  defp atomize_known_keys(attrs, keys) do
    Enum.reduce(keys, attrs, fn key, acc ->
      string_key = Atom.to_string(key)

      case {Map.fetch(acc, key), Map.fetch(acc, string_key)} do
        {:error, {:ok, value}} -> Map.put(acc, key, value)
        _other -> acc
      end
    end)
  end

  defp field(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp new_id(prefix), do: "#{prefix}_#{Ecto.UUID.generate()}"

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) do
    value
    |> normalize_string()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp normalize_string(value) do
    value
    |> to_string()
    |> String.trim()
  end

  defp normalize_limit(value) when is_integer(value) and value > 0, do: min(value, 100)

  defp normalize_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} -> normalize_limit(limit)
      _other -> @default_list_limit
    end
  end

  defp normalize_limit(_value), do: @default_list_limit

  defp present?(value), do: value not in [nil, ""]

  defp truthy?(value), do: value in [true, "true", "1", 1, "yes", "on"]

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
