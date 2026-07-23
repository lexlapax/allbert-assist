defmodule AllbertAssist.Conversations.ChannelThread do
  @moduledoc """
  Canonical conversation-thread mapping for external channel threading.

  This module owns ADR 0057 provider-ref normalization. Provider thread and
  message ids are lookup metadata only; `conversation_threads.id` remains the
  only canonical Allbert thread id.
  """

  import Ecto.Query

  alias AllbertAssist.Conversations.ConversationMessageRef
  alias AllbertAssist.Conversations.CrossChannelIdentityLink
  alias AllbertAssist.Conversations.Message
  alias AllbertAssist.Conversations.ThreadChannelRef
  alias AllbertAssist.Maps
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime.Redactor

  @owner_scope "local"
  @default_part_id "0"
  @hash_prefix "ptk_"
  @default_trust_class "server_readable"
  @trust_classes ~w[e2ee_origin server_readable local]
  @reply_key_types [:opaque_id, :timestamp]
  @timestamp_keys ~w[
    message_timestamp_ms
    quote_timestamp_ms
    sent_at_ms
    timestamp_ms
    message_timestamp
    timestamp
    thread_ts
    ts
  ]
  @author_keys ~w[
    author_aci
    sender_aci
    from_aci
    source_aci
    aci
    author_ref
    sender_ref
    external_user_id
    from
  ]
  @aci_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  @type normalized_ref :: %{
          owner_scope: String.t(),
          channel: String.t(),
          receiver_account_ref: String.t(),
          provider_thread_key: String.t(),
          provider_thread_ref: map(),
          trust_class: String.t()
        }

  @doc "Normalize a channel-owned provider thread ref for lookups and writes."
  @spec normalize_ref(String.t() | atom() | map(), map() | keyword()) ::
          {:ok, normalized_ref()} | {:error, term()}
  def normalize_ref(channel_or_attrs, attrs \\ %{})

  def normalize_ref(channel_or_attrs, attrs) when is_map(attrs) or is_list(attrs) do
    attrs = attrs |> to_attrs() |> maybe_put_channel(channel_or_attrs)
    provider_thread_ref = field(attrs, :provider_thread_ref) || %{}
    provider_thread_key = normalize_optional_string(field(attrs, :provider_thread_key))

    with {:ok, owner_scope} <- required_string(field(attrs, :owner_scope) || @owner_scope),
         {:ok, channel} <- required_string(field(attrs, :channel)),
         {:ok, receiver_account_ref} <- required_string(field(attrs, :receiver_account_ref)),
         {:ok, provider_thread_key} <-
           normalize_provider_thread_key(provider_thread_key, provider_thread_ref),
         {:ok, trust_class} <- normalize_trust_class(field(attrs, :trust_class)) do
      {:ok,
       %{
         owner_scope: owner_scope,
         channel: channel,
         receiver_account_ref: receiver_account_ref,
         provider_thread_key: provider_thread_key,
         provider_thread_ref: provider_thread_ref |> json_safe() |> Redactor.redact(),
         trust_class: trust_class
       }}
    end
  end

  def normalize_ref(_channel_or_attrs, _attrs), do: {:error, :invalid_channel_thread_ref}

  @doc "Return a deterministic bounded provider-thread key."
  @spec provider_thread_key(term()) :: String.t()
  def provider_thread_key(value) do
    @hash_prefix <>
      Base.url_encode64(:crypto.hash(:sha256, canonical_encode(value)), padding: false)
  end

  @doc "Return the normalized one-way identity digest stored in origin thread metadata."
  def identity_digest(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Look up an existing canonical thread id for a normalized provider ref."
  @spec lookup_thread(map()) :: {:ok, String.t()} | {:error, :not_found | term()}
  def lookup_thread(attrs) when is_map(attrs) do
    with {:ok, ref} <- normalize_ref(attrs) do
      case Repo.get_by(ThreadChannelRef, ref_keys(ref)) do
        %ThreadChannelRef{canonical_thread_id: thread_id} -> {:ok, thread_id}
        nil -> {:error, :not_found}
      end
    end
  end

  @doc "Bind a normalized provider thread ref to a canonical Allbert thread id."
  @spec link_thread(map()) :: {:ok, ThreadChannelRef.t()} | {:error, term()}
  def link_thread(attrs) when is_map(attrs) do
    with {:ok, ref} <- normalize_ref(attrs),
         {:ok, canonical_thread_id} <- required_string(field(attrs, :canonical_thread_id)) do
      attrs =
        ref
        |> Map.put(:canonical_thread_id, canonical_thread_id)

      case Repo.get_by(ThreadChannelRef, ref_keys(ref)) do
        nil ->
          %ThreadChannelRef{}
          |> ThreadChannelRef.changeset(attrs)
          |> Repo.insert()

        %ThreadChannelRef{canonical_thread_id: ^canonical_thread_id} = existing ->
          existing
          |> ThreadChannelRef.changeset(attrs)
          |> Repo.update()

        %ThreadChannelRef{} = existing ->
          {:error, {:thread_ref_conflict, existing.canonical_thread_id}}
      end
    end
  end

  @doc "Record one canonical message to provider message mapping."
  @spec record_message_ref(map()) :: {:ok, ConversationMessageRef.t()} | {:error, term()}
  def record_message_ref(attrs) when is_map(attrs) do
    with {:ok, normalized} <- normalize_message_ref(attrs) do
      case Repo.get_by(ConversationMessageRef, message_ref_keys(normalized)) do
        nil ->
          %ConversationMessageRef{}
          |> ConversationMessageRef.changeset(normalized)
          |> Repo.insert()

        %ConversationMessageRef{
          canonical_message_id: existing_message_id,
          direction: existing_direction
        } = existing
        when existing_message_id == normalized.canonical_message_id and
               existing_direction == normalized.direction ->
          {:ok, existing}

        %ConversationMessageRef{} = existing ->
          {:error,
           {:message_ref_conflict,
            %{
              canonical_message_id: existing.canonical_message_id,
              direction: existing.direction
            }}}
      end
    end
  end

  @doc "Return true when an inbound provider message matches a recorded outbound ref."
  @spec echo?(map()) :: boolean()
  def echo?(attrs) when is_map(attrs) do
    with {:ok, attrs} <- normalize_echo_ref(attrs) do
      query =
        from ref in ConversationMessageRef,
          where:
            ref.owner_scope == ^attrs.owner_scope and
              ref.channel == ^attrs.channel and
              ref.receiver_account_ref == ^attrs.receiver_account_ref and
              ref.provider_message_id == ^attrs.provider_message_id and
              ref.direction == "out",
          limit: 1

      query
      |> maybe_filter_message_part(attrs.part_id)
      |> Repo.one()
      |> is_nil()
      |> Kernel.not()
    else
      _error -> false
    end
  end

  def echo?(_attrs), do: false

  @doc "Look up the canonical thread that owns a provider message id."
  @spec lookup_message_thread(map()) :: {:ok, String.t()} | {:error, :not_found | term()}
  def lookup_message_thread(attrs) when is_map(attrs) do
    with {:ok, attrs} <- normalize_echo_ref(attrs) do
      query =
        from ref in ConversationMessageRef,
          where:
            ref.owner_scope == ^attrs.owner_scope and
              ref.channel == ^attrs.channel and
              ref.receiver_account_ref == ^attrs.receiver_account_ref and
              ref.provider_message_id == ^attrs.provider_message_id,
          order_by: [asc: ref.part_id],
          limit: 1

      query
      |> maybe_filter_message_part(attrs.part_id)
      |> Repo.one()
      |> case do
        %ConversationMessageRef{canonical_thread_id: thread_id} -> {:ok, thread_id}
        nil -> {:error, :not_found}
      end
    end
  end

  def lookup_message_thread(_attrs), do: {:error, :invalid_message_ref}

  @doc "Resolve a channel reply/thread target from a normalized ref and descriptor."
  @spec resolve_reply_target(map(), map()) ::
          {:ok,
           %{
             strategy: :flat_stream | :native_thread | :reply_chain | :rich_surface,
             threading: :flat | :native_threads | :reply_chain | :rich,
             declared_threading: :flat | :native_threads | :reply_chain | :rich,
             channel: binary(),
             receiver_account_ref: binary(),
             provider_thread_key: binary(),
             provider_thread_ref: map(),
             trust_class: atom(),
             reply_key_type: :opaque_id | :timestamp,
             reply_key: map(),
             quote_ttl_ms: pos_integer() | nil,
             quote_window: map() | nil,
             degradation: :none | :quote_ttl_expired
           }}
          | {:error,
             :invalid_channel_thread_ref
             | :invalid_threading_capability
             | :missing_provider_thread_key
             | :missing_provider_thread_ref
             | :missing_required_string}
  def resolve_reply_target(attrs, descriptor) when is_map(attrs) and is_map(descriptor) do
    with {:ok, ref} <- normalize_ref(attrs),
         {:ok, declared_threading} <- threading_capability(descriptor),
         {:ok, reply_key_type} <- reply_key_type(descriptor),
         {:ok, quote_ttl_ms} <- quote_ttl_ms(descriptor) do
      quote_window = quote_window(ref.provider_thread_ref, quote_ttl_ms, attrs, descriptor)
      threading = effective_threading(declared_threading, quote_window)

      {:ok,
       %{
         strategy: reply_strategy(threading),
         threading: threading,
         declared_threading: declared_threading,
         channel: ref.channel,
         receiver_account_ref: ref.receiver_account_ref,
         provider_thread_key: ref.provider_thread_key,
         provider_thread_ref: ref.provider_thread_ref,
         trust_class: trust_class_atom(ref.trust_class),
         reply_key_type: reply_key_type,
         reply_key: reply_key(reply_key_type, ref),
         quote_ttl_ms: quote_ttl_ms,
         quote_window: quote_window,
         degradation: degradation(declared_threading, threading, quote_window)
       }}
    end
  end

  @doc "Create an explicit cross-channel identity link entry."
  @spec link_identity(map()) :: {:ok, CrossChannelIdentityLink.t()} | {:error, term()}
  def link_identity(attrs) when is_map(attrs) do
    attrs = normalize_identity_link_attrs(attrs)

    with :ok <- validate_identity_link(attrs) do
      case Repo.get_by(CrossChannelIdentityLink, identity_link_keys(attrs)) do
        nil ->
          %CrossChannelIdentityLink{}
          |> CrossChannelIdentityLink.changeset(attrs)
          |> Repo.insert()

        %CrossChannelIdentityLink{user_id: existing_user_id} = existing
        when existing_user_id == attrs.user_id ->
          {:ok, existing}

        %CrossChannelIdentityLink{} = existing ->
          {:error, {:identity_link_conflict, existing.user_id}}
      end
    end
  end

  def link_identity(_attrs), do: {:error, :invalid_identity_link}

  @doc "List explicit cross-channel identity links."
  @spec list_identity_links(map()) :: [CrossChannelIdentityLink.t()]
  def list_identity_links(filters \\ %{}) when is_map(filters) do
    filters = normalize_identity_link_attrs(filters)

    CrossChannelIdentityLink
    |> where([link], link.owner_scope == ^Map.get(filters, :owner_scope, @owner_scope))
    |> maybe_filter(:link_id, Map.get(filters, :link_id))
    |> maybe_filter(:user_id, Map.get(filters, :user_id))
    |> maybe_filter(:channel, Map.get(filters, :channel))
    |> maybe_filter(:receiver_account_ref, Map.get(filters, :receiver_account_ref))
    |> order_by([link],
      asc: link.link_id,
      asc: link.channel,
      asc: link.receiver_account_ref,
      asc: link.external_user_id
    )
    |> Repo.all()
  end

  @doc "Delete one explicit cross-channel identity link entry."
  @spec unlink_identity(map()) :: {:ok, CrossChannelIdentityLink.t()} | {:error, term()}
  def unlink_identity(attrs) when is_map(attrs) do
    attrs = normalize_identity_link_attrs(attrs)

    case Repo.get_by(CrossChannelIdentityLink, identity_link_keys(attrs)) do
      nil -> {:error, :not_found}
      %CrossChannelIdentityLink{} = existing -> Repo.delete(existing)
    end
  end

  def unlink_identity(_attrs), do: {:error, :invalid_identity_link}

  defp normalize_message_ref(attrs) do
    attrs = atomize_message_ref_keys(attrs)

    with {:ok, owner_scope} <- required_string(field(attrs, :owner_scope) || @owner_scope),
         {:ok, channel} <- required_string(field(attrs, :channel)),
         {:ok, receiver_account_ref} <- required_string(field(attrs, :receiver_account_ref)),
         {:ok, provider_message_id} <- required_string(field(attrs, :provider_message_id)),
         {:ok, direction} <- normalize_direction(field(attrs, :direction)),
         {:ok, canonical_message_id} <- required_string(field(attrs, :canonical_message_id)),
         {:ok, canonical_thread_id} <-
           canonical_thread_id(canonical_message_id, field(attrs, :canonical_thread_id)),
         {:ok, part_id} <- required_string(field(attrs, :part_id) || @default_part_id),
         {:ok, trust_class} <- normalize_trust_class(field(attrs, :trust_class)) do
      {:ok,
       %{
         owner_scope: owner_scope,
         channel: channel,
         receiver_account_ref: receiver_account_ref,
         provider_message_id: provider_message_id,
         part_id: part_id,
         direction: direction,
         canonical_message_id: canonical_message_id,
         canonical_thread_id: canonical_thread_id,
         trust_class: trust_class
       }}
    end
  end

  defp normalize_echo_ref(attrs) do
    attrs = atomize_message_ref_keys(attrs)

    with {:ok, owner_scope} <- required_string(field(attrs, :owner_scope) || @owner_scope),
         {:ok, channel} <- required_string(field(attrs, :channel)),
         {:ok, receiver_account_ref} <- required_string(field(attrs, :receiver_account_ref)),
         {:ok, provider_message_id} <- required_string(field(attrs, :provider_message_id)),
         {:ok, part_id} <- optional_part_id(field(attrs, :part_id)) do
      {:ok,
       %{
         owner_scope: owner_scope,
         channel: channel,
         receiver_account_ref: receiver_account_ref,
         provider_message_id: provider_message_id,
         part_id: part_id
       }}
    end
  end

  defp normalize_provider_thread_key(nil, provider_thread_ref) do
    if blank_ref?(provider_thread_ref) do
      {:error, :missing_provider_thread_ref}
    else
      {:ok, provider_thread_key(provider_thread_ref)}
    end
  end

  defp normalize_provider_thread_key(key, _provider_thread_ref) do
    key
    |> normalize_string()
    |> case do
      "" -> {:error, :missing_provider_thread_key}
      key when byte_size(key) <= 160 -> {:ok, key}
      key -> {:ok, provider_thread_key(key)}
    end
  end

  defp canonical_thread_id(_canonical_message_id, value) when not is_nil(value),
    do: required_string(value)

  defp canonical_thread_id(canonical_message_id, _value) do
    case Repo.get(Message, canonical_message_id) do
      %Message{thread_id: thread_id} -> {:ok, thread_id}
      nil -> {:error, {:message_not_found, canonical_message_id}}
    end
  end

  defp threading_capability(descriptor) do
    case Map.get(descriptor, :threading, Map.get(descriptor, "threading")) do
      capability when capability in [:native_threads, :reply_chain, :flat, :rich] ->
        {:ok, capability}

      capability when capability in ["native_threads", "reply_chain", "flat", "rich"] ->
        {:ok, String.to_existing_atom(capability)}

      _other ->
        {:error, :invalid_threading_capability}
    end
  end

  defp reply_key_type(descriptor) do
    case field(descriptor, :reply_key_type) do
      nil -> {:ok, :opaque_id}
      value when value in @reply_key_types -> {:ok, value}
      value when value in ["opaque_id", "timestamp"] -> {:ok, String.to_existing_atom(value)}
      value -> {:error, {:invalid_reply_key_type, value}}
    end
  end

  defp quote_ttl_ms(descriptor) do
    case field(descriptor, :quote_ttl_ms) do
      nil -> {:ok, nil}
      value when is_integer(value) and value > 0 -> {:ok, value}
      value -> {:error, {:invalid_quote_ttl_ms, value}}
    end
  end

  defp quote_window(_provider_thread_ref, nil, _attrs, _descriptor), do: nil

  defp quote_window(provider_thread_ref, ttl_ms, attrs, descriptor) do
    checked_at = resolver_now(attrs, descriptor)
    quoted_at = quoted_at(provider_thread_ref)
    expires_at = if quoted_at, do: DateTime.add(quoted_at, ttl_ms, :millisecond)

    expired? =
      case quoted_at do
        %DateTime{} -> DateTime.diff(checked_at, quoted_at, :millisecond) > ttl_ms
        nil -> false
      end

    %{
      ttl_ms: ttl_ms,
      quoted_at: iso8601_or_nil(quoted_at),
      checked_at: iso8601_or_nil(checked_at),
      expires_at: iso8601_or_nil(expires_at),
      expired?: expired?
    }
  end

  defp effective_threading(:reply_chain, %{expired?: true}), do: :flat
  defp effective_threading(threading, _quote_window), do: threading

  defp degradation(:reply_chain, :flat, %{expired?: true}), do: :quote_ttl_expired
  defp degradation(_declared_threading, _threading, _quote_window), do: :none

  defp reply_key(:opaque_id, ref) do
    %{
      type: :opaque_id,
      key: ref.provider_thread_key
    }
  end

  defp reply_key(:timestamp, ref) do
    %{
      type: :timestamp,
      timestamp_ms: timestamp_ms(ref.provider_thread_ref),
      author_ref: first_string_value(ref.provider_thread_ref, @author_keys)
    }
  end

  defp reply_strategy(:native_threads), do: :native_thread
  defp reply_strategy(:reply_chain), do: :reply_chain
  defp reply_strategy(:flat), do: :flat_stream
  defp reply_strategy(:rich), do: :rich_surface

  defp trust_class_atom("e2ee_origin"), do: :e2ee_origin
  defp trust_class_atom("server_readable"), do: :server_readable
  defp trust_class_atom("local"), do: :local

  defp ref_keys(ref) do
    Map.take(ref, [:owner_scope, :channel, :receiver_account_ref, :provider_thread_key])
  end

  defp message_ref_keys(ref) do
    Map.take(ref, [:owner_scope, :channel, :receiver_account_ref, :provider_message_id, :part_id])
  end

  defp identity_link_keys(attrs) do
    attrs
    |> atomize_known_keys([
      :owner_scope,
      :link_id,
      :channel,
      :receiver_account_ref,
      :external_user_id
    ])
    |> Map.take([:owner_scope, :link_id, :channel, :receiver_account_ref, :external_user_id])
  end

  defp normalize_identity_link_attrs(attrs) do
    attrs
    |> atomize_known_keys([
      :owner_scope,
      :link_id,
      :user_id,
      :channel,
      :receiver_account_ref,
      :external_user_id
    ])
    |> Map.put_new(:owner_scope, @owner_scope)
    |> Map.update(:owner_scope, @owner_scope, &normalize_string/1)
    |> Map.update(:link_id, nil, &normalize_string/1)
    |> Map.update(:user_id, nil, &normalize_string/1)
    |> Map.update(:channel, nil, &normalize_string/1)
    |> Map.update(:receiver_account_ref, nil, &normalize_string/1)
    |> Map.update(:external_user_id, nil, &normalize_string/1)
    |> normalize_signal_identity()
  end

  defp validate_identity_link(%{channel: channel, external_user_id: external_user_id})
       when is_binary(channel) do
    if signal_channel?(channel) and not valid_signal_aci?(external_user_id) do
      {:error, {:invalid_signal_identity, :aci_required}}
    else
      :ok
    end
  end

  defp validate_identity_link(_attrs), do: :ok

  defp normalize_signal_identity(%{channel: channel, external_user_id: external_user_id} = attrs)
       when is_binary(channel) and is_binary(external_user_id) do
    if signal_channel?(channel) do
      Map.put(attrs, :external_user_id, normalize_signal_aci(external_user_id))
    else
      attrs
    end
  end

  defp normalize_signal_identity(attrs), do: attrs

  defp signal_channel?(channel), do: String.downcase(channel) == "signal"

  defp normalize_signal_aci(value) do
    value = normalize_string(value)

    if String.starts_with?(String.downcase(value), "aci:") do
      value |> String.split(":", parts: 2) |> List.last() |> normalize_string()
    else
      value
    end
  end

  defp valid_signal_aci?(value) when is_binary(value), do: Regex.match?(@aci_regex, value)
  defp valid_signal_aci?(_value), do: false

  defp maybe_filter(query, _field, value) when value in [nil, ""], do: query
  defp maybe_filter(query, :link_id, value), do: where(query, [link], link.link_id == ^value)
  defp maybe_filter(query, :user_id, value), do: where(query, [link], link.user_id == ^value)
  defp maybe_filter(query, :channel, value), do: where(query, [link], link.channel == ^value)

  defp maybe_filter(query, :receiver_account_ref, value),
    do: where(query, [link], link.receiver_account_ref == ^value)

  defp maybe_filter_message_part(query, nil), do: query

  defp maybe_filter_message_part(query, part_id),
    do: where(query, [ref], ref.part_id == ^part_id)

  defp normalize_direction(value) when value in [:in, "in"], do: {:ok, "in"}
  defp normalize_direction(value) when value in [:out, "out"], do: {:ok, "out"}
  defp normalize_direction(_value), do: {:error, :invalid_direction}

  defp normalize_trust_class(nil), do: {:ok, @default_trust_class}

  defp normalize_trust_class(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_trust_class()

  defp normalize_trust_class(value) when is_binary(value) do
    value = value |> String.trim() |> String.trim_leading(":")

    if value in @trust_classes do
      {:ok, value}
    else
      {:error, {:invalid_trust_class, value}}
    end
  end

  defp normalize_trust_class(value), do: {:error, {:invalid_trust_class, value}}

  defp maybe_put_channel(attrs, channel) when is_map(channel), do: Map.merge(channel, attrs)
  defp maybe_put_channel(attrs, _channel) when is_map_key(attrs, :channel), do: attrs
  defp maybe_put_channel(attrs, channel), do: Map.put(attrs, :channel, channel)

  defp blank_ref?(value), do: value in [nil, %{}, "", []]

  defp required_string(value) do
    value
    |> normalize_string()
    |> case do
      "" -> {:error, :missing_required_string}
      value -> {:ok, value}
    end
  end

  defp optional_part_id(nil), do: {:ok, nil}
  defp optional_part_id(value), do: required_string(value)

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(value), do: normalize_string(value)

  defp resolver_now(attrs, descriptor) do
    value =
      field(attrs, :now) ||
        field(attrs, :checked_at) ||
        field(descriptor, :now) ||
        DateTime.utc_now()

    normalize_datetime(value)
  end

  defp quoted_at(provider_thread_ref) do
    provider_thread_ref
    |> timestamp_ms()
    |> case do
      nil -> nil
      timestamp_ms -> DateTime.from_unix!(timestamp_ms, :millisecond)
    end
  end

  defp timestamp_ms(value) do
    value
    |> first_value(@timestamp_keys)
    |> normalize_timestamp_ms()
  end

  defp first_string_value(value, keys) do
    case first_value(value, keys) do
      nil ->
        nil

      value ->
        case normalize_string(value) do
          "" -> nil
          string -> string
        end
    end
  end

  defp first_value(%{} = map, keys) do
    direct =
      keys
      |> Enum.find_value(&map_get_string_or_existing_atom(map, &1))

    if is_nil(direct) do
      map
      |> Map.values()
      |> Enum.find_value(&first_value(&1, keys))
    else
      direct
    end
  end

  defp first_value(list, keys) when is_list(list),
    do: Enum.find_value(list, &first_value(&1, keys))

  defp first_value(_value, _keys), do: nil

  defp map_get_string_or_existing_atom(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        try do
          Map.get(map, String.to_existing_atom(key))
        rescue
          ArgumentError -> nil
        end
    end
  end

  defp normalize_datetime(%DateTime{} = datetime), do: datetime

  defp normalize_datetime(%NaiveDateTime{} = datetime) do
    DateTime.from_naive!(datetime, "Etc/UTC")
  end

  defp normalize_datetime(value) when is_integer(value) do
    value
    |> normalize_timestamp_ms()
    |> DateTime.from_unix!(:millisecond)
  end

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> DateTime.utc_now()
    end
  end

  defp normalize_datetime(_value), do: DateTime.utc_now()

  defp normalize_timestamp_ms(nil), do: nil

  defp normalize_timestamp_ms(value) when is_integer(value) do
    if abs(value) >= 10_000_000_000 do
      value
    else
      value * 1_000
    end
  end

  defp normalize_timestamp_ms(value) when is_float(value) do
    if abs(value) >= 10_000_000_000 do
      trunc(value)
    else
      trunc(value * 1_000)
    end
  end

  defp normalize_timestamp_ms(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      nil
    else
      parse_timestamp_string(value)
    end
  end

  defp normalize_timestamp_ms(_value), do: nil

  defp iso8601_or_nil(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601_or_nil(nil), do: nil

  defp parse_timestamp_string(value) do
    case Integer.parse(value) do
      {integer, ""} ->
        normalize_timestamp_ms(integer)

      _integer_error ->
        parse_timestamp_float_or_iso8601(value)
    end
  end

  defp parse_timestamp_float_or_iso8601(value) do
    case Float.parse(value) do
      {float, ""} ->
        normalize_timestamp_ms(float)

      _float_error ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
          {:error, _reason} -> nil
        end
    end
  end

  defp normalize_string(value) do
    value
    |> to_string()
    |> String.trim()
  end

  defp atomize_message_ref_keys(attrs) do
    atomize_known_keys(attrs, [
      :owner_scope,
      :canonical_message_id,
      :canonical_thread_id,
      :channel,
      :receiver_account_ref,
      :provider_message_id,
      :part_id,
      :direction,
      :trust_class
    ])
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

  defp to_attrs(attrs) when is_map(attrs), do: attrs
  defp to_attrs(attrs) when is_list(attrs), do: Map.new(attrs)

  defp json_safe(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp json_safe(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)
  defp json_safe(%Date{} = date), do: Date.to_iso8601(date)
  defp json_safe(%Time{} = time), do: Time.to_iso8601(time)

  defp json_safe(%{} = map) do
    Map.new(map, fn {key, value} -> {json_safe_key(key), json_safe(value)} end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)

  defp json_safe(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp json_safe(tuple) when is_tuple(tuple), do: inspect(tuple)
  defp json_safe(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp json_safe(value), do: inspect(value)

  defp json_safe_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_safe_key(key) when is_binary(key), do: key
  defp json_safe_key(key), do: inspect(key)

  defp canonical_encode(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, item} -> {to_string(key), item} end)
      |> Enum.sort_by(fn {key, _item} -> key end)
      |> Enum.map_join(",", fn {key, item} ->
        Jason.encode!(key) <> ":" <> canonical_encode(item)
      end)

    "{" <> entries <> "}"
  end

  defp canonical_encode(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &canonical_encode/1) <> "]"
  end

  defp canonical_encode(value), do: Jason.encode!(json_safe(value))
end
