defmodule AllbertAssist.Conversations.UnifiedHistory do
  @moduledoc """
  Read model and resume helper for canonical conversation continuity.

  The persisted authority remains `conversation_threads.id`. Channel provider
  ids are lookup metadata for placement, dedupe, and operator inspection.
  """

  import Ecto.Query

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.LocalSurface
  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Conversations.ConversationMessageRef
  alias AllbertAssist.Conversations.Message
  alias AllbertAssist.Conversations.Thread
  alias AllbertAssist.Conversations.ThreadChannelRef
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime.Redactor

  @default_limit 50
  @max_limit 200
  @local_channels ~w(cli live_view web)

  @type history :: %{
          thread: Thread.t(),
          messages: [map()],
          channels: [map()],
          thread_refs: [map()],
          ordering: :allbert_ingest_sequence,
          redaction: :runtime_redactor
        }

  @doc "Return a redacted, read-mostly unified history for one user-owned thread."
  @spec show_thread(String.t(), String.t(), keyword()) :: {:ok, history()} | {:error, term()}
  def show_thread(user_id, thread_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> normalize_limit()

    with {:ok, %{thread: thread, messages: messages}} <-
           Conversations.show_thread(user_id, thread_id, limit: limit) do
      message_refs = message_refs(messages)
      thread_refs = thread_refs(thread.id)
      refs_by_message = Enum.group_by(message_refs, & &1.canonical_message_id)

      {:ok,
       %{
         thread: thread,
         messages: Enum.map(messages, &message_view(&1, refs_by_message)),
         channels: channel_summaries(thread_refs, message_refs),
         thread_refs: Enum.map(thread_refs, &thread_ref_view/1),
         ordering: :allbert_ingest_sequence,
         redaction: :runtime_redactor
       }}
    end
  end

  @doc """
  Link or prepare a target channel surface for an explicit thread resume.

  External channels require the target external user identity to be explicitly
  linked to the same local `user_id` before a canonical thread can be resumed
  there. Local surfaces are already controlled by Allbert and do not require a
  cross-channel identity link.
  """
  @spec resume_thread_on_channel(map()) :: {:ok, map()} | {:error, term()}
  def resume_thread_on_channel(attrs) when is_map(attrs) do
    attrs = atomize_known_keys(attrs, known_resume_keys())

    with {:ok, user_id} <- required_string(field(attrs, :user_id)),
         {:ok, thread_id} <- required_string(field(attrs, :thread_id)),
         {:ok, channel} <- required_string(field(attrs, :channel)),
         {:ok, thread} <- Conversations.get_thread(user_id, thread_id),
         {:ok, descriptor} <- descriptor_for(channel),
         {:ok, target_ref} <- resume_target_ref(thread, descriptor, attrs),
         :ok <- require_explicit_identity_link(thread, target_ref, attrs),
         {:ok, linked_ref} <-
           target_ref
           |> Map.put(:canonical_thread_id, thread.id)
           |> ChannelThread.link_thread(),
         {:ok, reply_target} <- ChannelThread.resolve_reply_target(target_ref, descriptor) do
      {:ok,
       %{
         status: :resumed,
         thread_id: thread.id,
         user_id: thread.user_id,
         channel: reply_target.channel,
         receiver_account_ref: reply_target.receiver_account_ref,
         provider_thread_key: reply_target.provider_thread_key,
         reply_target: reply_target,
         continuity: continuity(reply_target),
         thread_ref_id: linked_ref.id
       }}
    end
  end

  def resume_thread_on_channel(_attrs), do: {:error, :invalid_resume_attrs}

  @doc "Return the operator-facing continuity mode for a resolved reply target."
  @spec continuity(map()) :: map()
  def continuity(%{strategy: :native_thread, threading: threading}) do
    %{mode: :native_thread, threading: threading, degradation: :none}
  end

  def continuity(%{strategy: :reply_chain, threading: threading}) do
    %{mode: :reply_chain, threading: threading, degradation: :reply_chain}
  end

  def continuity(%{strategy: :flat_stream, threading: threading}) do
    %{mode: :flat_stream, threading: threading, degradation: :flat}
  end

  def continuity(%{strategy: :rich_surface, threading: threading}) do
    %{mode: :rich_surface, threading: threading, degradation: :none}
  end

  def continuity(_target), do: %{mode: :unknown, threading: nil, degradation: :unknown}

  defp message_refs([]), do: []

  defp message_refs(messages) do
    ids = Enum.map(messages, & &1.id)

    ConversationMessageRef
    |> where([ref], ref.canonical_message_id in ^ids)
    |> order_by([ref],
      asc: ref.canonical_message_id,
      asc: ref.channel,
      asc: ref.receiver_account_ref,
      asc: ref.provider_message_id,
      asc: ref.part_id
    )
    |> Repo.all()
  end

  defp thread_refs(thread_id) do
    ThreadChannelRef
    |> where([ref], ref.canonical_thread_id == ^thread_id)
    |> order_by([ref],
      asc: ref.channel,
      asc: ref.receiver_account_ref,
      asc: ref.provider_thread_key
    )
    |> Repo.all()
  end

  defp message_view(%Message{} = message, refs_by_message) do
    refs =
      refs_by_message
      |> Map.get(message.id, [])
      |> Enum.map(&message_ref_view/1)

    %{
      id: message.id,
      thread_id: message.thread_id,
      user_id: message.user_id,
      role: message.role,
      content: Redactor.redact(message.content, :live_view),
      trace_id: Redactor.redact(message.trace_id, :live_view),
      metadata: Redactor.redact(message.metadata || %{}, :live_view),
      inserted_at: message.inserted_at,
      ingest_key: ingest_key(message),
      channel_refs: refs
    }
  end

  defp message_ref_view(%ConversationMessageRef{} = ref) do
    %{
      channel: ref.channel,
      receiver_account_ref: ref.receiver_account_ref,
      provider_message_id: Redactor.redact(ref.provider_message_id, :live_view),
      part_id: ref.part_id,
      direction: ref.direction
    }
  end

  defp thread_ref_view(%ThreadChannelRef{} = ref) do
    %{
      channel: ref.channel,
      receiver_account_ref: ref.receiver_account_ref,
      provider_thread_key: ref.provider_thread_key,
      provider_thread_ref: Redactor.redact(ref.provider_thread_ref || %{}, :live_view)
    }
  end

  defp channel_summaries(thread_refs, message_refs) do
    channels =
      (Enum.map(thread_refs, &{&1.channel, &1.receiver_account_ref}) ++
         Enum.map(message_refs, &{&1.channel, &1.receiver_account_ref}))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.map(channels, fn {channel, receiver_account_ref} ->
      refs =
        Enum.filter(message_refs, fn ref ->
          ref.channel == channel and ref.receiver_account_ref == receiver_account_ref
        end)

      thread_ref_count =
        Enum.count(thread_refs, fn ref ->
          ref.channel == channel and ref.receiver_account_ref == receiver_account_ref
        end)

      %{
        channel: channel,
        receiver_account_ref: receiver_account_ref,
        message_ref_count: length(refs),
        thread_ref_count: thread_ref_count,
        directions: refs |> Enum.map(& &1.direction) |> Enum.uniq() |> Enum.sort()
      }
    end)
  end

  defp ingest_key(%Message{} = message) do
    "#{DateTime.to_iso8601(message.inserted_at)}:#{message.id}"
  end

  defp descriptor_for(channel) do
    case Channels.channel_descriptor(channel) do
      {:ok, descriptor} -> {:ok, descriptor}
      {:error, :unknown_channel} -> LocalSurface.descriptor(channel)
    end
  end

  defp resume_target_ref(%Thread{} = thread, %{channel_id: channel}, attrs)
       when channel in @local_channels do
    with {:ok, ref} <-
           LocalSurface.thread_ref(channel, %{
             thread_id: thread.id,
             user_id: thread.user_id,
             session_id: field(attrs, :session_id),
             request_id: field(attrs, :request_id)
           }) do
      {:ok, ref.channel_thread_ref}
    end
  end

  defp resume_target_ref(_thread, %{channel_id: channel}, attrs) do
    with {:ok, receiver_account_ref} <- required_string(field(attrs, :receiver_account_ref)),
         {:ok, provider_thread_ref} <- provider_thread_ref(attrs),
         {:ok, provider_thread_key} <- provider_thread_key(attrs, provider_thread_ref) do
      {:ok,
       %{
         owner_scope: normalize_string(field(attrs, :owner_scope) || "local"),
         channel: channel,
         receiver_account_ref: receiver_account_ref,
         provider_thread_key: provider_thread_key,
         provider_thread_ref: provider_thread_ref
       }}
    end
  end

  defp require_explicit_identity_link(_thread, %{channel: channel}, _attrs)
       when channel in @local_channels,
       do: :ok

  defp require_explicit_identity_link(%Thread{} = thread, target_ref, attrs) do
    with {:ok, external_user_id} <- required_string(field(attrs, :external_user_id)) do
      links =
        ChannelThread.list_identity_links(%{
          owner_scope: Map.get(target_ref, :owner_scope, "local"),
          user_id: thread.user_id,
          channel: target_ref.channel,
          receiver_account_ref: target_ref.receiver_account_ref
        })

      if Enum.any?(links, &(&1.external_user_id == external_user_id)) do
        :ok
      else
        {:error, :missing_identity_link}
      end
    else
      {:error, :missing_required_string} -> {:error, :missing_external_user_id}
      error -> error
    end
  end

  defp provider_thread_ref(attrs) do
    case field(attrs, :provider_thread_ref) do
      value when value in [nil, "", %{}, []] ->
        case field(attrs, :provider_thread_key) do
          value when value in [nil, ""] -> {:error, :missing_provider_thread_ref}
          key -> {:ok, %{"provider_thread_key" => normalize_string(key)}}
        end

      value when is_map(value) ->
        {:ok, value}

      value ->
        {:ok, %{"provider_thread_ref" => normalize_string(value)}}
    end
  end

  defp provider_thread_key(attrs, provider_thread_ref) do
    case field(attrs, :provider_thread_key) do
      value when value in [nil, ""] ->
        {:ok, ChannelThread.provider_thread_key(provider_thread_ref)}

      value ->
        required_string(value)
    end
  end

  defp normalize_limit(value) when is_integer(value) and value > 0, do: min(value, @max_limit)

  defp normalize_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> min(integer, @max_limit)
      _other -> @default_limit
    end
  end

  defp normalize_limit(_value), do: @default_limit

  defp known_resume_keys do
    [
      :channel,
      :external_user_id,
      :owner_scope,
      :provider_thread_key,
      :provider_thread_ref,
      :receiver_account_ref,
      :request_id,
      :session_id,
      :thread_id,
      :user_id
    ]
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

  defp field(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp required_string(value) do
    value
    |> normalize_string()
    |> case do
      "" -> {:error, :missing_required_string}
      value -> {:ok, value}
    end
  end

  defp normalize_string(nil), do: ""

  defp normalize_string(value) do
    value
    |> to_string()
    |> String.trim()
  end
end
