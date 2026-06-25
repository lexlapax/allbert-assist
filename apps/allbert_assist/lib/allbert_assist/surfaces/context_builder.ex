defmodule AllbertAssist.Surfaces.ContextBuilder do
  @moduledoc """
  Shared context builders for local and web surface action invocations.

  These helpers keep surface identity, actor, request, and response-target fields
  consistent while preserving the caller's explicit params.
  """

  @default_user_id "local"

  @spec cli_context(map() | keyword()) :: map()
  def cli_context(opts \\ %{}) do
    opts = to_map(opts)
    user_id = field(opts, :user_id) || field(opts, :operator_id) || @default_user_id
    operator_id = field(opts, :operator_id) || user_id
    surface = field(opts, :surface) || "cli"
    source = field(opts, :source) || surface

    %{
      actor: field(opts, :actor) || user_id,
      user_id: user_id,
      operator_id: operator_id,
      channel: field(opts, :channel) || :cli,
      surface: surface,
      request:
        compact(%{
          channel: field(opts, :channel) || :cli,
          user_id: user_id,
          operator_id: operator_id,
          source: source,
          app_id: field(opts, :app_id)
        })
    }
    |> merge_optional(opts, [
      :thread_id,
      :session_id,
      :active_app,
      :response_target,
      :source,
      :audit?,
      :app_id,
      :selected_skill
    ])
  end

  @spec live_view_context(map(), map() | keyword()) :: map()
  def live_view_context(socket_or_assigns, opts \\ %{}) do
    opts = to_map(opts)
    assigns = assigns(socket_or_assigns)
    user_id = first_field([opts, assigns], :user_id, @default_user_id)
    operator_id = field(opts, :operator_id) || user_id
    session_id = first_field([opts, assigns], :session_id)
    thread_id = first_field([opts, assigns], :thread_id)
    active_app = first_field([opts, assigns], :active_app)
    canvas_destination = first_field([opts, assigns], :canvas_destination)
    surface = field(opts, :surface) || "AllbertAssistWeb.WorkspaceLive"
    response_target = field(opts, :response_target) || field(socket_or_assigns, :id)
    channel = field(opts, :channel) || :live_view

    %{
      actor: field(opts, :actor) || user_id,
      user_id: user_id,
      operator_id: operator_id,
      thread_id: thread_id,
      session_id: session_id,
      active_app: active_app,
      canvas_destination: canvas_destination,
      channel: channel,
      surface: surface,
      response_target: response_target,
      request:
        compact(%{
          channel: channel,
          user_id: user_id,
          operator_id: operator_id,
          thread_id: thread_id,
          session_id: session_id,
          active_app: active_app,
          source: surface
        })
    }
    |> compact()
  end

  @spec channel_context(String.t() | atom(), String.t(), map() | keyword()) :: map()
  def channel_context(channel, user_id, opts \\ %{}) do
    opts = to_map(opts)
    channel = field(opts, :channel) || channel
    user_id = field(opts, :user_id) || user_id
    operator_id = field(opts, :operator_id) || user_id
    surface = field(opts, :surface) || "#{channel}_callback"
    session_id = field(opts, :session_id)
    actor = field(opts, :actor) || user_id

    %{
      actor: actor,
      user_id: user_id,
      operator_id: operator_id,
      channel: channel,
      surface: surface,
      session_id: session_id,
      provider: field(opts, :provider),
      external_user_id: field(opts, :external_user_id),
      external_chat_id: field(opts, :external_chat_id),
      receiver_account_ref: field(opts, :receiver_account_ref),
      session: field(opts, :session),
      request:
        compact(%{
          user_id: user_id,
          operator_id: operator_id,
          channel: channel,
          provider: field(opts, :provider),
          surface: surface,
          session_id: session_id,
          source: surface,
          external_user_id: field(opts, :external_user_id),
          external_chat_id: field(opts, :external_chat_id),
          receiver_account_ref: field(opts, :receiver_account_ref),
          actor: actor,
          session: field(opts, :session)
        })
    }
    |> compact()
    |> merge_optional(opts, [:thread_id, :response_target, :resolver_metadata])
  end

  @spec public_protocol_context(String.t(), String.t(), map() | keyword()) :: map()
  def public_protocol_context(surface, client_id, opts \\ %{}) do
    opts = to_map(opts)
    surface = normalize_string(surface, "mcp_stdio")
    client_id = normalize_string(client_id, "stdio-client")
    channel = field(opts, :channel) || channel_for_surface(surface)
    operator_id = field(opts, :operator_id) || "public-protocol:#{client_id}"

    %{
      actor: field(opts, :actor) || operator_id,
      user_id: field(opts, :user_id) || operator_id,
      operator_id: operator_id,
      channel: channel,
      surface: surface,
      public_protocol: %{surface: surface, client_id: client_id},
      request:
        compact(%{
          channel: channel,
          user_id: field(opts, :user_id),
          operator_id: operator_id,
          source: surface
        })
    }
    |> merge_optional(opts, [:thread_id, :session_id, :active_app, :response_target, :audit?])
  end

  defp assigns(%{assigns: assigns}) when is_map(assigns), do: assigns
  defp assigns(assigns) when is_map(assigns), do: assigns
  defp assigns(_value), do: %{}

  defp merge_optional(context, opts, keys) do
    Enum.reduce(keys, context, fn key, acc ->
      case field(opts, key) do
        nil -> acc
        "" -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp compact(map) do
    Map.reject(map, fn
      {_key, nil} -> true
      {_key, ""} -> true
      _entry -> false
    end)
  end

  defp to_map(opts) when is_map(opts), do: opts
  defp to_map(opts) when is_list(opts), do: Map.new(opts)
  defp to_map(_opts), do: %{}

  defp first_field(sources, key, default \\ nil) do
    Enum.find_value(sources, default, &field(&1, key))
  end

  defp normalize_string(value, default) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> default
      value -> value
    end
  end

  defp normalize_string(_value, default), do: default

  defp channel_for_surface("mcp_stdio"), do: :mcp_stdio
  defp channel_for_surface("mcp_http"), do: :mcp_http
  defp channel_for_surface("acp_stdio"), do: :acp_stdio
  defp channel_for_surface("acp"), do: :acp
  defp channel_for_surface("openai_api"), do: :openai_api
  defp channel_for_surface(surface), do: surface

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_map, _key), do: nil
end
