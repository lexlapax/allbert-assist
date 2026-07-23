defmodule AllbertAssist.Channels.LocalSurface do
  @moduledoc """
  Rich local surface descriptors and provider refs for CLI and web turns.

  These surfaces are controlled by Allbert and do not need transport adapters,
  but v0.52 still records their turns through the ADR 0057 channel-thread
  substrate so unified history can treat them like other channel surfaces.
  """

  alias AllbertAssist.Conversations.ChannelThread

  @cli %{
    channel_id: "cli",
    provider: "local_cli",
    primitives: [:typed_command, :list],
    threading: :rich,
    trust_class: :local,
    receiver_account_ref: "cli:default"
  }

  @live_view %{
    channel_id: "live_view",
    provider: "phoenix_live_view",
    primitives: [:button, :typed_command, :list],
    threading: :rich,
    streaming: :live_region,
    trust_class: :local,
    receiver_account_ref: "web:workspace"
  }

  def descriptors, do: [@cli, @live_view]

  @spec descriptor(atom() | String.t()) :: {:ok, map()} | {:error, :unknown_local_surface}
  def descriptor(channel) do
    case normalize_channel(channel) do
      "cli" -> {:ok, @cli}
      "live_view" -> {:ok, @live_view}
      "web" -> {:ok, @live_view}
      _channel -> {:error, :unknown_local_surface}
    end
  end

  @spec thread_ref(atom() | String.t(), map() | keyword()) ::
          {:ok, %{channel_thread_ref: map(), provider_message_id: String.t(), metadata: map()}}
          | {:error, :unknown_local_surface}
  def thread_ref(channel, attrs \\ %{}) do
    attrs = Map.new(attrs)

    with {:ok, descriptor} <- descriptor(channel) do
      request_id = request_id(attrs)
      provider_thread_ref = provider_thread_ref(descriptor, attrs, request_id)
      provider_message_id = "#{descriptor.channel_id}:in:#{request_id}"

      {:ok,
       %{
         channel_thread_ref: %{
           channel: descriptor.channel_id,
           receiver_account_ref: descriptor.receiver_account_ref,
           provider_thread_key: ChannelThread.provider_thread_key(provider_thread_ref),
           provider_thread_ref: provider_thread_ref
         },
         provider_message_id: provider_message_id,
         metadata: %{
           local_surface: descriptor.channel_id,
           local_surface_provider: descriptor.provider,
           receiver_account_ref: descriptor.receiver_account_ref,
           provider_thread_ref: provider_thread_ref,
           provider_message_id: provider_message_id
         }
       }}
    end
  end

  defp provider_thread_ref(descriptor, attrs, request_id) do
    %{
      provider: descriptor.provider,
      surface: descriptor.channel_id,
      provider_thread_root: provider_thread_root(attrs, request_id),
      thread_id: blank_to_nil(Map.get(attrs, :thread_id)),
      session_id: blank_to_nil(Map.get(attrs, :session_id)),
      user_id: blank_to_nil(Map.get(attrs, :user_id))
    }
    |> compact()
  end

  defp provider_thread_root(attrs, request_id) do
    cond do
      present?(Map.get(attrs, :thread_id)) -> "thread:#{Map.fetch!(attrs, :thread_id)}"
      present?(Map.get(attrs, :session_id)) -> "session:#{Map.fetch!(attrs, :session_id)}"
      true -> "turn:#{request_id}"
    end
  end

  defp request_id(attrs) do
    case blank_to_nil(Map.get(attrs, :request_id)) do
      nil -> Ecto.UUID.generate()
      value -> value
    end
  end

  defp normalize_channel(channel) do
    channel
    |> to_string()
    |> String.trim()
  end

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp present?(value), do: not is_nil(blank_to_nil(value))

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    value =
      value
      |> to_string()
      |> String.trim()

    if value == "", do: nil, else: value
  end
end
