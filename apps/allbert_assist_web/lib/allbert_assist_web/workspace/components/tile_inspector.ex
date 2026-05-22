defmodule AllbertAssistWeb.Workspace.Components.TileInspector do
  @moduledoc "Workspace tile inspector modal."

  use AllbertAssistWeb, :live_component

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="workspace-approval-overlay workspace-tile-inspector-overlay">
      <section
        id="workspace-tile-inspector"
        class="workspace-approval-modal workspace-tile-inspector-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="workspace-tile-inspector-title"
        aria-describedby="workspace-tile-inspector-summary"
        tabindex="-1"
        phx-hook="FocusTrap"
        phx-window-keydown="close_tile_inspector"
        phx-key="escape"
      >
        <header class="workspace-tile-inspector-header">
          <div class="workspace-tile-inspector-title-block">
            <p class="workspace-approval-eyebrow">Tile inspector</p>
            <h2 id="workspace-tile-inspector-title" class="workspace-tile-inspector-title">
              {tile_title(@tile)}
            </h2>
            <p id="workspace-tile-inspector-summary" class="workspace-pane-subtitle">
              {tile_kind(@tile)} tile · {short_id(tile_id(@tile))}
            </p>
          </div>
          <button
            id="workspace-tile-inspector-close"
            type="button"
            class="allbert-icon-button"
            aria-label="Close tile inspector"
            title="Close"
            phx-click="close_tile_inspector"
          >
            <.icon name="hero-x-mark-micro" class="size-4" />
          </button>
        </header>

        <div class="workspace-tile-inspector-grid">
          <section
            class="workspace-tile-inspector-section"
            aria-labelledby="workspace-tile-inspector-meta-title"
          >
            <h3
              id="workspace-tile-inspector-meta-title"
              class="workspace-tile-inspector-section-title"
            >
              Metadata
            </h3>
            <dl class="workspace-tile-inspector-meta">
              <div :for={row <- metadata_rows(@tile)} class="workspace-tile-inspector-meta-row">
                <dt>{row.label}</dt>
                <dd class="workspace-mono">{row.value}</dd>
              </div>
            </dl>
          </section>

          <section
            class="workspace-tile-inspector-section"
            aria-labelledby="workspace-tile-inspector-provenance-title"
          >
            <h3
              id="workspace-tile-inspector-provenance-title"
              class="workspace-tile-inspector-section-title"
            >
              Provenance
            </h3>
            <dl class="workspace-tile-inspector-meta">
              <div :for={row <- provenance_rows(@tile)} class="workspace-tile-inspector-meta-row">
                <dt>{row.label}</dt>
                <dd class="workspace-mono">{row.value}</dd>
              </div>
            </dl>
            <a
              :if={trace = trace_link(@tile)}
              id="workspace-tile-inspector-trace-link"
              class="workspace-trace-link mt-2"
              href={trace.href}
            >
              <.icon name="hero-link-micro" class="size-4" />
              <span class="workspace-mono">{trace.label}</span>
            </a>
            <p :if={is_nil(trace_link(@tile))} class="workspace-tile-inspector-muted">
              No trace link is attached to this tile.
            </p>
          </section>
        </div>

        <section
          class="workspace-tile-inspector-section"
          aria-labelledby="workspace-tile-inspector-body-title"
        >
          <div class="workspace-tile-inspector-section-header">
            <h3
              id="workspace-tile-inspector-body-title"
              class="workspace-tile-inspector-section-title"
            >
              Body
            </h3>
            <button
              id="workspace-tile-inspector-copy-body"
              type="button"
              class="allbert-chip workspace-copy-target"
              phx-hook="CopyToClipboard"
              data-copy-value={body_text(@tile)}
            >
              <.icon name="hero-clipboard-document-micro" class="size-4" /> Copy body
            </button>
          </div>
          <pre id="workspace-tile-inspector-body" class="workspace-tile-inspector-body">{body_text(@tile)}</pre>
        </section>

        <footer class="workspace-tile-inspector-footer">
          <button
            id="workspace-tile-inspector-copy-id"
            type="button"
            class="allbert-chip workspace-copy-target"
            phx-hook="CopyToClipboard"
            data-copy-value={tile_id(@tile)}
          >
            <.icon name="hero-clipboard-document-micro" class="size-4" /> Copy tile id
          </button>
          <button
            type="button"
            class="workspace-button workspace-button-secondary"
            phx-click="close_tile_inspector"
          >
            Close
          </button>
        </footer>
      </section>
    </div>
    """
  end

  defp metadata_rows(tile) do
    [
      row("Tile id", tile_id(tile)),
      row("Kind", tile_kind(tile)),
      row("User", value(tile, :user_id)),
      row("Thread", value(tile, :thread_id)),
      row("Pinned", bool_text(value(tile, :pinned))),
      row("Read only", bool_text(value(tile, :read_only))),
      row("Revision", value(tile, :current_revision_id)),
      row("Body path", value(tile, :body_yaml_path))
    ]
    |> Enum.reject(&blank?(&1.value))
  end

  defp provenance_rows(tile) do
    [
      row(
        "Emitter",
        first_present([fragment_value(tile, :emitter_id), metadata_value(tile, :emitter_id)])
      ),
      row(
        "Emitted at",
        first_present([fragment_value(tile, :emitted_at), metadata_value(tile, :emitted_at)])
      ),
      row("Scope", first_present([fragment_value(tile, :scope), metadata_value(tile, :scope)])),
      row("Updated", value(tile, :updated_at)),
      row("Deleted", value(tile, :deleted_at))
    ]
    |> Enum.reject(&blank?(&1.value))
    |> case do
      [] -> [row("Source", "workspace")]
      rows -> rows
    end
  end

  defp row(label, value), do: %{label: label, value: string_value(value)}

  defp trace_link(tile) do
    case find_trace_node(value(tile, :body)) do
      %{href: href, label: label} when is_binary(href) and href != "" and href != "#" ->
        %{href: href, label: label || href}

      _other ->
        case first_present([
               metadata_value(tile, :trace_id),
               fragment_metadata_value(tile, :trace_id)
             ]) do
          nil -> nil
          trace_id -> %{href: "#", label: string_value(trace_id)}
        end
    end
  end

  defp find_trace_node(%{} = body) do
    body
    |> nested_value([:surface, :nodes])
    |> List.wrap()
    |> Enum.find_value(&trace_node/1)
  end

  defp find_trace_node(_body), do: nil

  defp trace_node(%{} = node) do
    component = nested_value(node, [:component])

    if component in [:trace_link, "trace_link"] do
      props = nested_value(node, [:props]) || %{}

      %{
        href: nested_value(props, [:href]),
        label: nested_value(props, [:body]) || nested_value(props, [:label])
      }
    else
      node
      |> nested_value([:children])
      |> List.wrap()
      |> Enum.find_value(&trace_node/1)
    end
  end

  defp trace_node(_node), do: nil

  defp tile_title(tile) do
    first_present([
      nested_value(value(tile, :body), [:surface, :label]),
      nested_value(value(tile, :body), [:title]),
      "Canvas tile #{short_id(tile_id(tile))}"
    ])
  end

  defp body_text(tile) do
    case value(tile, :body) do
      nil ->
        "Tile body could not be loaded."

      body when is_map(body) ->
        body
        |> maybe_body_text()
        |> first_present([
          inspect(body, pretty: true, limit: :infinity, printable_limit: :infinity)
        ])

      body ->
        string_value(body)
    end
  end

  defp maybe_body_text(body) when is_map(body) do
    first_present([
      nested_value(body, [:text]),
      nested_value(body, [:markdown]),
      nested_value(body, [:content]),
      nested_value(body, [:snapshot])
    ])
  end

  defp tile_id(tile), do: value(tile, :id)
  defp tile_kind(tile), do: value(tile, :kind) || "tile"

  defp value(%{} = map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp value(_map, _key), do: nil

  defp metadata_value(tile, key) do
    tile
    |> value(:metadata)
    |> nested_value([key])
  end

  defp fragment_value(tile, key) do
    tile
    |> value(:body)
    |> nested_value([:fragment, key])
  end

  defp fragment_metadata_value(tile, key) do
    tile
    |> value(:body)
    |> nested_value([:fragment, :metadata, key])
  end

  defp nested_value(nil, _keys), do: nil

  defp nested_value(value, []), do: value

  defp nested_value(%{} = map, [key | rest]) do
    map
    |> value(key)
    |> nested_value(rest)
  end

  defp nested_value(_value, _keys), do: nil

  defp first_present(values) when is_list(values) do
    Enum.find(values, fn value -> !blank?(value) end)
  end

  defp first_present(value, fallbacks) when is_list(fallbacks),
    do: first_present([value | fallbacks])

  defp string_value(nil), do: nil
  defp string_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp string_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp string_value(value) when is_binary(value), do: value
  defp string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp string_value(value), do: inspect(value, pretty: true)

  defp bool_text(true), do: "yes"
  defp bool_text(false), do: "no"
  defp bool_text(value), do: value

  defp short_id(nil), do: "unknown"

  defp short_id(id) when is_binary(id) do
    if String.length(id) > 16, do: String.slice(id, 0, 12) <> "...", else: id
  end

  defp short_id(id), do: string_value(id)

  defp blank?(value), do: value in [nil, ""]
end
