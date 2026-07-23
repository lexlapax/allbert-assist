defmodule AllbertAssist.Channels.ChannelParity do
  @moduledoc """
  Descriptor-derived channel parity matrix.

  The matrix is generated from registered channel descriptors plus the declared
  local surfaces. Streaming posture is declared by each descriptor; descriptors
  without the additive field retain the `:turn_complete` default.
  """

  alias AllbertAssist.Capabilities.ReleaseAvailability
  alias AllbertAssist.Channels.LocalSurface
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry

  @streaming_modes [:turn_complete, :progress_messages, :live_region]

  @type row :: %{
          required(:channel) => String.t(),
          required(:kind) => :registered_channel | :local_surface,
          required(:provider) => String.t(),
          required(:plugin_id) => String.t() | nil,
          required(:source) => atom(),
          required(:primitives) => [atom()],
          required(:threading) => atom(),
          required(:identity_mapping) => String.t(),
          required(:approval_rendering) => String.t(),
          required(:attachments) => String.t(),
          required(:streaming) => String.t(),
          required(:outbound) => String.t(),
          required(:release_status) => atom(),
          required(:live_use_allowed?) => boolean()
        }

  @spec matrix(keyword()) :: [row()]
  def matrix(opts \\ []) do
    registered =
      opts
      |> registered_channels()
      |> Enum.map(&row(&1, :registered_channel))

    local =
      LocalSurface.descriptors()
      |> Enum.map(&row(&1, :local_surface))

    (registered ++ local)
    |> Enum.sort_by(&{row_order(&1), &1.channel})
  end

  defp registered_channels(opts) do
    case Keyword.fetch(opts, :registered_channels) do
      {:ok, descriptors} when is_list(descriptors) -> descriptors
      _other -> PluginRegistry.registered_channels(opts)
    end
  end

  @spec verify(keyword()) :: :ok | {:error, [map()]}
  def verify(opts \\ []) do
    errors =
      opts
      |> matrix()
      |> Enum.flat_map(&row_errors/1)

    case errors do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  @spec table(keyword()) :: String.t()
  def table(opts \\ []) do
    rows = matrix(opts)

    [
      [
        "channel",
        "kind",
        "provider",
        "primitives",
        "threading",
        "identity",
        "approval",
        "attachments",
        "streaming",
        "outbound",
        "release",
        "live"
      ]
      | Enum.map(rows, &table_row/1)
    ]
    |> format_rows()
  end

  defp row(descriptor, kind) do
    channel = descriptor.channel_id
    release = ReleaseAvailability.decision({:channel, channel})

    %{
      channel: channel,
      kind: kind,
      provider: descriptor.provider,
      plugin_id: Map.get(descriptor, :plugin_id),
      source: Map.get(descriptor, :source, local_source(kind)),
      primitives: Map.get(descriptor, :primitives, []),
      threading: Map.get(descriptor, :threading),
      identity_mapping: identity_mapping(descriptor, kind),
      approval_rendering: approval_rendering(Map.get(descriptor, :primitives, [])),
      attachments: attachments(channel),
      streaming: streaming(descriptor),
      outbound: outbound(descriptor, kind),
      release_status: release.release_status,
      live_use_allowed?: release.live_use_allowed?
    }
  end

  defp row_errors(row) do
    []
    |> maybe_error(row.primitives == [], row, :missing_primitives)
    |> maybe_error(:list not in row.primitives, row, :missing_list_fallback)
    |> maybe_error(is_nil(row.threading), row, :missing_threading)
    |> maybe_error(
      row.streaming not in Enum.map(@streaming_modes, &Atom.to_string/1),
      row,
      :invalid_streaming
    )
    |> maybe_error(live_region_not_local?(row), row, :live_region_not_local)
  end

  defp streaming(descriptor) do
    case Map.get(descriptor, :streaming, :turn_complete) do
      mode when mode in @streaming_modes -> Atom.to_string(mode)
      mode when is_atom(mode) -> Atom.to_string(mode)
      mode when is_binary(mode) -> mode
      mode -> inspect(mode)
    end
  end

  defp live_region_not_local?(%{
         streaming: "live_region",
         kind: :registered_channel,
         channel: channel
       }),
       do: channel != "tui"

  defp live_region_not_local?(_row), do: false

  defp maybe_error(errors, false, _row, _reason), do: errors

  defp maybe_error(errors, true, row, reason) do
    [%{channel: row.channel, reason: reason} | errors]
  end

  defp identity_mapping(%{identity_map_key: key}, :registered_channel) when is_binary(key),
    do: key

  defp identity_mapping(%{channel_id: channel}, :registered_channel),
    do: "channels.#{channel}.identity_map"

  defp identity_mapping(%{receiver_account_ref: receiver}, :local_surface)
       when is_binary(receiver),
       do: "local_surface:#{receiver}"

  defp approval_rendering(primitives) do
    primitives
    |> Enum.map(&Atom.to_string/1)
    |> Enum.join("+")
  end

  defp attachments("telegram"), do: "voice_inbound; media_output_links"
  defp attachments("email"), do: "attachments_blocked"
  defp attachments(channel) when channel in ["discord", "slack"], do: "media_output_links"
  defp attachments(_channel), do: "none"

  defp outbound(_descriptor, :local_surface), do: "n/a"

  defp outbound(%{adapter: module}, :registered_channel) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        if function_exported?(module, :deliver_outbound, 3), do: "implemented", else: "none"

      _other ->
        "unknown"
    end
  end

  defp outbound(%{child_spec: {module, _opts}}, :registered_channel) when is_atom(module) do
    outbound(%{adapter: module}, :registered_channel)
  end

  defp outbound(_descriptor, :registered_channel), do: "none"

  defp table_row(row) do
    [
      row.channel,
      kind_label(row.kind),
      row.provider,
      approval_rendering(row.primitives),
      to_string(row.threading),
      row.identity_mapping,
      row.approval_rendering,
      row.attachments,
      row.streaming,
      row.outbound,
      to_string(row.release_status),
      to_string(row.live_use_allowed?)
    ]
  end

  defp format_rows(rows) do
    widths =
      rows
      |> Enum.zip()
      |> Enum.map(fn column ->
        column
        |> Tuple.to_list()
        |> Enum.map(&String.length/1)
        |> Enum.max()
      end)

    rows
    |> Enum.map(fn row ->
      row
      |> Enum.zip(widths)
      |> Enum.map_join("  ", fn {cell, width} -> String.pad_trailing(cell, width) end)
      |> String.trim_trailing()
    end)
    |> Enum.join("\n")
  end

  defp row_order(%{kind: :local_surface}), do: 0
  defp row_order(%{channel: "telegram"}), do: 1
  defp row_order(%{channel: "email"}), do: 2
  defp row_order(%{kind: :registered_channel}), do: 10

  defp kind_label(:registered_channel), do: "channel"
  defp kind_label(:local_surface), do: "local"

  defp local_source(:local_surface), do: :local_surface
  defp local_source(_kind), do: :unknown
end
