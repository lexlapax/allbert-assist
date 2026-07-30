defmodule AllbertAssist.Conversations do
  @moduledoc """
  SQLite conversation history for local workspace identity.

  Conversation rows are separate from markdown memory. They provide ordered,
  user-scoped turn history for runtime context and operator inspection.
  """

  import Ecto.Query

  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Conversations.Message
  alias AllbertAssist.Conversations.Thread
  alias AllbertAssist.Database.TransientError
  alias AllbertAssist.Jobs.Managed
  alias AllbertAssist.Maps
  alias AllbertAssist.Repo
  alias AllbertAssist.Workspace.Ephemeral

  @default_kind "general"
  @default_list_limit 20
  @default_context_limit 12
  @default_admission_attempts 3
  @default_admission_retry_delay_ms 25
  @fanout_report_message_prefix "msg_fanout_report_"

  @type thread_result :: {:ok, Thread.t()} | {:error, term()}

  @doc "Create a general conversation thread for a local string user id."
  @spec create_thread(map()) :: thread_result()
  def create_thread(attrs) when is_map(attrs) do
    now = utc_now()

    attrs =
      attrs
      |> atomize_known_keys([
        :id,
        :user_id,
        :title,
        :kind,
        :app_id,
        :last_message_at,
        :completed_at
      ])
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

  @doc """
  Rename a thread's operator-facing title, scoped to the owning `user_id`.

  v0.61b M4: only the persisted `title` field value changes — internal
  `Conversations.Thread` modules/atoms/topics/keys are untouched (v0.58
  no-internal-rename invariant).
  """
  @spec rename_thread(String.t(), String.t(), String.t()) :: thread_result()
  def rename_thread(user_id, thread_id, title) do
    with {:ok, thread} <- get_thread(user_id, thread_id) do
      thread
      |> Thread.title_changeset(title)
      |> Repo.update()
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
        where: is_nil(thread.completed_at),
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

  @doc "Fetch one message only when it belongs to `user_id`."
  @spec get_message(String.t(), String.t()) :: {:ok, Message.t()} | {:error, term()}
  def get_message(user_id, message_id) do
    user_id = normalize_string(user_id)
    message_id = normalize_string(message_id)

    query =
      from message in Message,
        where: message.id == ^message_id and message.user_id == ^user_id

    case Repo.one(query) do
      %Message{} = message -> {:ok, message}
      nil -> {:error, {:message_not_found, message_id}}
    end
  end

  @doc "Return the stable canonical message id for one fan-out join report."
  @spec fanout_report_message_id(String.t()) :: String.t()
  def fanout_report_message_id(parent_id) when is_binary(parent_id) and parent_id != "",
    do: @fanout_report_message_prefix <> parent_id

  @doc "True when the owned thread already contains the canonical fan-out report message."
  @spec fanout_report_message?(String.t(), String.t(), String.t()) :: boolean()
  def fanout_report_message?(user_id, thread_id, parent_id)
      when is_binary(user_id) and is_binary(thread_id) and is_binary(parent_id) and
             parent_id != "" do
    message_id = fanout_report_message_id(parent_id)

    Repo.exists?(
      from message in Message,
        where:
          message.id == ^message_id and message.user_id == ^user_id and
            message.thread_id == ^thread_id and message.role == "assistant"
    )
  end

  def fanout_report_message?(_user_id, _thread_id, _parent_id), do: false

  @doc "Fetch one user/thread-scoped message by its originating input signal id."
  @spec get_message_by_input_signal(String.t(), String.t(), String.t()) ::
          {:ok, Message.t()} | {:error, term()}
  def get_message_by_input_signal(user_id, thread_id, input_signal_id) do
    user_id = normalize_string(user_id)
    thread_id = normalize_string(thread_id)
    input_signal_id = normalize_optional_string(input_signal_id)

    if is_nil(input_signal_id) do
      {:error, :missing_input_signal_id}
    else
      query =
        from message in Message,
          where:
            message.user_id == ^user_id and message.thread_id == ^thread_id and
              message.input_signal_id == ^input_signal_id,
          order_by: [desc: message.inserted_at, desc: message.id],
          limit: 1

      case Repo.one(query) do
        %Message{} = message -> {:ok, message}
        nil -> {:error, {:message_not_found_by_input_signal, input_signal_id}}
      end
    end
  end

  @doc "Mark a user-scoped thread complete and dismiss its active ephemeral surfaces."
  @spec complete_thread(String.t(), String.t()) :: thread_result()
  def complete_thread(user_id, thread_id) do
    with {:ok, thread} <- get_thread(user_id, thread_id),
         {:ok, {%Thread{} = completed, dismissed}} <-
           Repo.transaction(fn -> complete_thread_and_dismiss_ephemerals(thread) end) do
      Ephemeral.publish_thread_dismissals(dismissed)
      {:ok, completed}
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

  @doc "Atomically admit one inbound user message and its normalized provider references."
  @spec admit_user_message(Thread.t(), String.t(), map() | keyword()) ::
          {:ok, %{message: Message.t(), channel_thread_ref: map() | nil}}
          | {:error, {:inbound_admission_failed, atom()}}
  def admit_user_message(%Thread{completed_at: completed_at}, _content, _attrs)
      when not is_nil(completed_at),
      do: {:error, {:inbound_admission_failed, :thread_completed}}

  def admit_user_message(%Thread{} = thread, content, attrs) when is_binary(content) do
    attrs = to_attrs(attrs)
    timestamp = utc_now()

    admission = fn ->
      with {:ok, origin} <- prepare_admission_origin(thread, attrs),
           message_attrs <- inbound_message_attrs(thread, attrs, content, origin),
           message <- insert_message_and_touch_thread(thread, message_attrs, timestamp),
           :ok <- admit_message_ref(thread, message, origin, attrs) do
        %{
          message: message,
          channel_thread_ref: canonical_origin_ref(origin.thread_ref)
        }
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end

    case run_inbound_admission(admission) do
      {:ok, admitted} ->
        kick_search_reconcile(thread.user_id)
        {:ok, admitted}

      {:error, reason} ->
        {:error, {:inbound_admission_failed, admission_error(reason)}}
    end
  end

  def admit_user_message(_thread, _content, _attrs),
    do: {:error, {:inbound_admission_failed, :invalid_message}}

  @doc "Append an assistant-authored message to a thread."
  @spec append_assistant_message(Thread.t(), String.t(), map() | keyword()) ::
          {:ok, Message.t()} | {:error, term()}
  def append_assistant_message(%Thread{} = thread, content, attrs \\ %{}) do
    append_message(thread, Map.merge(to_attrs(attrs), %{role: "assistant", content: content}))
  end

  @doc """
  Ensure one assistant-authored message with a caller-owned stable id.

  Repeating the same write returns the existing message without moving the
  thread's last-message timestamp. Reusing the id for different content,
  metadata, role, user, or thread fails closed.
  """
  @spec ensure_assistant_message(Thread.t(), String.t(), String.t(), map() | keyword()) ::
          {:ok, Message.t()} | {:error, term()}
  def ensure_assistant_message(thread, id, content, attrs \\ %{})

  def ensure_assistant_message(%Thread{completed_at: completed_at}, _id, _content, _attrs)
      when not is_nil(completed_at),
      do: {:error, :thread_completed}

  def ensure_assistant_message(%Thread{} = thread, id, content, attrs)
      when is_binary(id) and is_binary(content) do
    now = utc_now()

    message_attrs =
      thread
      |> message_attrs(Map.merge(to_attrs(attrs), %{id: id, role: "assistant", content: content}))

    case Repo.transaction(
           fn -> ensure_message_and_touch_thread(thread, message_attrs, now) end,
           mode: :immediate
         ) do
      {:ok, message} -> {:ok, message}
      {:error, reason} -> {:error, reason}
    end
  end

  def ensure_assistant_message(_thread, _id, _content, _attrs),
    do: {:error, :invalid_message_attrs}

  @doc "Append one message and update the parent thread's last-message timestamp."
  @spec append_message(Thread.t(), map()) :: {:ok, Message.t()} | {:error, term()}
  def append_message(%Thread{completed_at: completed_at}, _attrs) when not is_nil(completed_at),
    do: {:error, :thread_completed}

  def append_message(%Thread{} = thread, attrs) when is_map(attrs) do
    now = utc_now()
    attrs = message_attrs(thread, attrs)

    case Repo.transaction(fn -> insert_message_and_touch_thread(thread, attrs, now) end) do
      {:ok, message} ->
        kick_search_reconcile(thread.user_id)
        {:ok, message}

      {:error, reason} ->
        {:error, reason}
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

  defp complete_thread_and_dismiss_ephemerals(%Thread{completed_at: nil} = thread) do
    timestamp = utc_now()

    with {:ok, completed} <- Repo.update(Thread.complete_changeset(thread, timestamp)),
         {:ok, dismissed} <-
           Ephemeral.dismiss_for_thread_transaction(
             completed.id,
             completed.user_id,
             :thread_closed
           ) do
      {completed, dismissed}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp complete_thread_and_dismiss_ephemerals(%Thread{} = thread) do
    with {:ok, dismissed} <-
           Ephemeral.dismiss_for_thread_transaction(thread.id, thread.user_id, :thread_closed) do
      {thread, dismissed}
    else
      {:error, reason} -> Repo.rollback(reason)
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

  defp ensure_message_and_touch_thread(thread, attrs, timestamp) do
    case Repo.get(Message, attrs.id) do
      nil ->
        insert_message_and_touch_thread(thread, attrs, timestamp)

      %Message{} = existing ->
        if idempotent_message_match?(existing, attrs) do
          existing
        else
          Repo.rollback({:message_idempotency_conflict, attrs.id})
        end
    end
  end

  defp idempotent_message_match?(message, attrs) do
    fields = [
      :thread_id,
      :user_id,
      :role,
      :content,
      :action_log,
      :metadata,
      :origin_thread_ref_id,
      :origin_principal_digest,
      :principal_normalizer_version,
      :trace_id,
      :input_signal_id,
      :response_signal_id
    ]

    Map.take(Map.from_struct(message), fields) == Map.take(attrs, fields)
  end

  defp inbound_message_attrs(thread, attrs, content, origin) do
    attrs
    |> Map.drop([
      :channel_thread_ref,
      :provider_message_id,
      :provider_message_part_id,
      :external_user_id
    ])
    |> Map.merge(%{role: "user", content: content})
    |> Map.merge(origin.message_attrs)
    |> then(&message_attrs(thread, &1))
  end

  defp canonical_origin_ref(nil), do: nil
  defp canonical_origin_ref(thread_ref), do: ChannelThread.canonical_ref(thread_ref)

  defp prepare_admission_origin(thread, attrs) do
    case Map.get(attrs, :channel_thread_ref) do
      nil ->
        {:ok, %{thread_ref: nil, ref_attrs: nil, message_attrs: %{}}}

      ref ->
        ref = Map.put(ref, :canonical_thread_id, thread.id)

        with {:ok, thread_ref} <- ChannelThread.link_thread(ref),
             {:ok, principal_digest} <- admission_principal_digest(thread, ref, attrs) do
          {:ok,
           %{
             thread_ref: thread_ref,
             ref_attrs: ref,
             message_attrs: %{
               origin_thread_ref_id: thread_ref.id,
               origin_principal_digest: principal_digest,
               principal_normalizer_version: ChannelThread.principal_normalizer_version()
             }
           }}
        end
    end
  end

  defp admit_message_ref(_thread, _message, %{ref_attrs: nil}, _attrs), do: :ok

  defp admit_message_ref(thread, message, origin, attrs) do
    case Map.get(attrs, :provider_message_id) do
      nil ->
        :ok

      provider_message_id ->
        origin.ref_attrs
        |> Map.merge(%{
          canonical_message_id: message.id,
          canonical_thread_id: thread.id,
          provider_message_id: provider_message_id,
          part_id: Map.get(attrs, :provider_message_part_id),
          direction: :in,
          thread_channel_ref_id: origin.thread_ref.id
        })
        |> ChannelThread.record_message_ref()
        |> case do
          {:ok, _message_ref} -> :ok
          {:error, reason} -> {:error, {:message_reference, reason}}
        end
    end
  end

  defp admission_principal_digest(thread, ref, attrs) do
    case to_string(Map.get(ref, :trust_class, Map.get(ref, "trust_class", "server_readable"))) do
      "local" ->
        {:ok, ChannelThread.principal_digest(thread.user_id)}

      _remote ->
        remote_principal_digest(ref, attrs)
    end
  end

  defp remote_principal_digest(ref, attrs) do
    external_user_id = Map.get(attrs, :external_user_id)
    provider_ref = Map.get(ref, :provider_thread_ref, Map.get(ref, "provider_thread_ref", %{}))

    if is_binary(external_user_id) and String.trim(external_user_id) != "" do
      {:ok, ChannelThread.principal_digest(external_user_id)}
    else
      provider_principal_digest(provider_ref)
    end
  end

  defp provider_principal_digest(provider_ref) when is_map(provider_ref) do
    case Map.get(provider_ref, :origin_identity_digest) ||
           Map.get(provider_ref, "origin_identity_digest") do
      digest when is_binary(digest) -> {:ok, normalize_principal_digest(digest)}
      _other -> {:error, :missing_origin_principal}
    end
  end

  defp provider_principal_digest(_provider_ref), do: {:error, :missing_origin_principal}

  defp normalize_principal_digest("sha256:" <> digest), do: "sha256:" <> String.downcase(digest)
  defp normalize_principal_digest(digest), do: "sha256:" <> String.downcase(digest)

  defp run_inbound_admission(admission) do
    config = Application.get_env(:allbert_assist, __MODULE__, [])
    attempts = Keyword.get(config, :transaction_attempts, @default_admission_attempts)
    delay_ms = Keyword.get(config, :transaction_retry_delay_ms, @default_admission_retry_delay_ms)
    delay_fun = Keyword.get(config, :transaction_retry_delay_fun, &Process.sleep/1)

    do_run_inbound_admission(admission, attempts, delay_ms, delay_fun)
  end

  defp do_run_inbound_admission(admission, attempts, delay_ms, delay_fun) do
    case safely_run_inbound_admission(admission) do
      {:error, :persistence_unavailable} when attempts > 1 ->
        delay_fun.(delay_ms)
        do_run_inbound_admission(admission, attempts - 1, delay_ms, delay_fun)

      result ->
        result
    end
  end

  defp safely_run_inbound_admission(admission) do
    inbound_transaction_runner().(admission)
  rescue
    exception ->
      if TransientError.transient?(exception) do
        {:error, :persistence_unavailable}
      else
        reraise exception, __STACKTRACE__
      end
  catch
    :exit, reason ->
      if TransientError.transient?(reason) do
        {:error, :persistence_unavailable}
      else
        exit(reason)
      end
  end

  defp inbound_transaction_runner do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:transaction_runner, fn admission ->
      Repo.transaction(admission, mode: :immediate)
    end)
  end

  defp admission_error({:message_reference, _reason}), do: :invalid_message_reference
  defp admission_error({:thread_ref_conflict, _thread_id}), do: :thread_reference_conflict
  defp admission_error(:missing_origin_principal), do: :origin_principal_unverified
  defp admission_error(:thread_completed), do: :thread_completed
  defp admission_error(:persistence_unavailable), do: :persistence_unavailable
  defp admission_error(%Ecto.Changeset{}), do: :invalid_message
  defp admission_error(_reason), do: :persistence_failure

  defp kick_search_reconcile(user_id) do
    case Managed.kick("search-index", user_id) do
      {:ok, _result} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp message_attrs(%Thread{} = thread, attrs) do
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
    |> Map.update!(:action_log, &json_safe/1)
    |> Map.update!(:metadata, &json_safe/1)
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

  defp field(attrs, key), do: Maps.field_truthy(attrs, key)

  defp json_safe(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp json_safe(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)
  defp json_safe(%Date{} = date), do: Date.to_iso8601(date)
  defp json_safe(%Time{} = time), do: Time.to_iso8601(time)

  defp json_safe(%{} = map) do
    Map.new(map, fn {key, value} -> {json_safe_key(key), json_safe(value)} end)
  end

  # `Enum.map/2` raises on an improper list (non-`[]` tail); json_safe must be
  # total AND produce a JSON-encodable (proper) list so a malformed
  # action_log/metadata value cannot crash the caller (a channel adapter
  # recording a trace) nor break downstream Jason encoding. A non-list tail is
  # folded in as a final element, turning `[a | "x"]` into `["a", "x"]`.
  defp json_safe([head | tail]) when is_list(tail), do: [json_safe(head) | json_safe(tail)]
  defp json_safe([head | tail]), do: [json_safe(head), json_safe(tail)]
  defp json_safe([]), do: []

  defp json_safe(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp json_safe(tuple) when is_tuple(tuple), do: inspect(tuple)
  defp json_safe(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp json_safe(value), do: inspect(value)

  defp json_safe_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_safe_key(key) when is_binary(key), do: key
  defp json_safe_key(key), do: inspect(key)

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
