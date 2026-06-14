defmodule AllbertAssistWeb.Workspace.Components.Chat do
  @moduledoc """
  Workspace fallback renderer for the existing `/workspace` runtime chat loop.
  """

  use AllbertAssistWeb, :live_component

  @impl true
  def update(assigns, socket) do
    state = Map.get(assigns, :workspace_state, %{})
    context = Map.get(assigns, :renderer_context, %{})

    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       active_objectives: Map.get(context, :active_objectives, []),
       conversation_messages: Map.get(context, :conversation_messages, []),
       unified_history: Map.get(context, :unified_history),
       prompt: Map.get(state, :prompt, ""),
       prompt_placeholder: Map.get(state, :prompt_placeholder, "Ask the agent something..."),
       response: Map.get(state, :response),
       error: Map.get(state, :error),
       thread_notice: Map.get(state, :thread_notice),
       asking?: Map.get(state, :asking?, false),
       status: Map.get(state, :status),
       signal_id: Map.get(state, :signal_id),
       trace_id: Map.get(state, :trace_id),
       approval_handoff: Map.get(state, :approval_handoff),
       approval_lines: Map.get(state, :approval_lines, []),
       approval_result: Map.get(state, :approval_result),
       show_approval_details?: Map.get(state, :show_approval_details?, false),
       voice_capture: Map.get(state, :voice_capture, %{status: :idle}),
       image_input: Map.get(state, :image_input, %{status: :idle}),
       voice_capture_upload: Map.get(context, :voice_capture_upload),
       image_input_upload: Map.get(context, :image_input_upload),
       composer_max_bytes: Map.get(context, :composer_max_bytes, 65_536),
       maximized_pane: Map.get(context, :workspace_maximized_pane)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id="workspace-chat-region"
      class="workspace-chat-pane"
      data-workspace-component={@node.component}
      aria-labelledby="workspace-chat-title"
    >
      <header class="workspace-pane-header workspace-chat-header">
        <div class="workspace-pane-title-block">
          <h2 id="workspace-chat-title" class="workspace-pane-title">Chat</h2>
          <p class="workspace-pane-subtitle">Runtime conversation</p>
        </div>
        <div :if={@active_objectives != []} id="objective-badges" class="workspace-objective-badges">
          <.link
            :for={objective <- @active_objectives}
            id={"objective-badge-#{objective.id}"}
            navigate={~p"/objectives/#{objective.id}"}
            class="allbert-chip"
          >
            <.icon name="hero-flag-micro" class="size-4" />
            <span>{objective.status}</span>
          </.link>
        </div>
        <button
          id="workspace-chat-maximize"
          type="button"
          class="allbert-icon-button workspace-pane-maximize"
          phx-click="toggle_workspace_maximize"
          phx-value-pane="chat"
          aria-pressed={bool_attribute(@maximized_pane == "chat")}
          aria-label={maximize_label("chat", @maximized_pane)}
          title={maximize_label("chat", @maximized_pane)}
        >
          <.icon
            name={
              if @maximized_pane == "chat",
                do: "hero-arrows-pointing-in-micro",
                else: "hero-arrows-pointing-out-micro"
            }
            class="size-4"
          />
        </button>
      </header>

      <%= if @thread_notice do %>
        <section id="workspace-thread-notice" class="workspace-thread-notice" role="status">
          <.icon name="hero-information-circle-micro" class="size-4 shrink-0" />
          <span>{@thread_notice}</span>
        </section>
      <% end %>

      <section
        :if={unified_history_messages(@unified_history) != []}
        id="workspace-unified-history"
        class="workspace-unified-history"
        data-channel-count={length(unified_history_channels(@unified_history))}
        aria-labelledby="workspace-unified-history-title"
      >
        <div class="workspace-unified-history-header">
          <h3 id="workspace-unified-history-title">Continuity</h3>
          <span class="workspace-unified-history-order">Allbert order</span>
        </div>
        <ol class="workspace-unified-history-list">
          <li
            :for={message <- unified_history_messages(@unified_history)}
            id={"workspace-unified-history-#{message.id}"}
            class="workspace-unified-history-item"
          >
            <span class="workspace-unified-history-role">{message.role}</span>
            <span class="workspace-unified-history-content">{message.content}</span>
            <span class="workspace-unified-history-channels">
              <span :if={message.channel_refs == []} class="workspace-unified-history-channel">
                local
              </span>
              <span
                :for={ref <- message.channel_refs}
                class="workspace-unified-history-channel"
                data-channel={ref.channel}
                data-trust-class={ref.trust_class}
                title={ref.receiver_account_ref}
              >
                {ref.channel}
              </span>
            </span>
          </li>
        </ol>
      </section>

      <div
        id="workspace-chat-timeline"
        class="workspace-chat-timeline"
        aria-live="polite"
        phx-hook="ChatAutoScroll"
      >
        <% latest_assistant_id = latest_assistant_message_id(@conversation_messages) %>
        <article
          :for={message <- @conversation_messages}
          id={timeline_message_dom_id(message, latest_assistant_id)}
          class={["workspace-message", message_class(message)]}
        >
          <div class="workspace-message-avatar" aria-hidden="true">
            {message_avatar(message)}
          </div>
          <div class="workspace-message-body">
            <p class="workspace-message-label">{message_label(message)}</p>
            <pre>{message_content(message)}</pre>
            <div :if={message_media_outputs(message) != []} class="workspace-media-outputs">
              <figure
                :for={{output, index} <- Enum.with_index(message_media_outputs(message))}
                class="workspace-media-output"
                data-media-kind={media_output_kind(output)}
              >
                <img
                  :if={media_output_kind(output) == "image"}
                  class="workspace-media-output-image"
                  src={media_output_src(message, index)}
                  alt={media_output_alt(output)}
                  style="display: block; width: min(100%, 28rem); height: 12rem; object-fit: contain;"
                  loading="lazy"
                />
                <audio
                  :if={media_output_kind(output) == "audio"}
                  class="workspace-media-output-audio"
                  src={media_output_src(message, index)}
                  controls
                  preload="metadata"
                >
                </audio>
                <figcaption class="workspace-media-output-meta">
                  {media_output_label(output)}
                </figcaption>
              </figure>
            </div>
            <time
              :if={message_time(message)}
              class="workspace-message-time"
              datetime={message_time(message)}
            >
              {relative_time(message_time(message))}
            </time>
            <%= if message_id(message) == latest_assistant_id do %>
              <dl class="workspace-runtime-meta">
                <div :if={@status} id="agent-status">
                  <dt>Status</dt>
                  <dd>{@status}</dd>
                </div>
                <div :if={@signal_id} id="agent-signal">
                  <dt>Signal</dt>
                  <dd
                    class="workspace-mono workspace-copy-target"
                    phx-hook="CopyToClipboard"
                    id={"agent-signal-copy-#{@signal_id}"}
                    data-copy-value={@signal_id}
                    role="button"
                    tabindex="0"
                    title="Copy signal id"
                  >
                    {@signal_id}
                  </dd>
                </div>
                <div :if={@trace_id} id="agent-trace">
                  <dt>Trace</dt>
                  <dd
                    class="workspace-mono workspace-copy-target"
                    phx-hook="CopyToClipboard"
                    id={"agent-trace-copy-#{@trace_id}"}
                    data-copy-value={@trace_id}
                    role="button"
                    tabindex="0"
                    title="Copy trace id"
                  >
                    {@trace_id}
                  </dd>
                </div>
              </dl>
            <% end %>
          </div>
        </article>

        <article
          :if={show_runtime_response?(@conversation_messages, @response)}
          id="agent-response"
          class="workspace-message workspace-message-agent"
        >
          <div class="workspace-message-avatar" aria-hidden="true">A</div>
          <div class="workspace-message-body">
            <p class="workspace-message-label">Allbert</p>
            <pre><%= @response %></pre>
            <dl class="workspace-runtime-meta">
              <div :if={@status} id="agent-status">
                <dt>Status</dt>
                <dd>{@status}</dd>
              </div>
              <div :if={@signal_id} id="agent-signal">
                <dt>Signal</dt>
                <dd class="workspace-mono">{@signal_id}</dd>
              </div>
              <div :if={@trace_id} id="agent-trace">
                <dt>Trace</dt>
                <dd class="workspace-mono">{@trace_id}</dd>
              </div>
            </dl>
          </div>
        </article>

        <section
          :if={@conversation_messages == [] and !@response and !prompt_present?(@prompt)}
          class="workspace-chat-empty"
        >
          <span class="workspace-empty-state-icon" aria-hidden="true">
            <.icon name="hero-sparkles-mini" class="size-5" />
          </span>
          <p>
            Ask Allbert to start a runtime turn. Canvas tiles and approvals appear beside the chat.
          </p>
        </section>
      </div>

      <form
        id="agent-form"
        phx-submit="ask"
        phx-change="composer_change"
        class="workspace-composer"
        aria-busy={bool_attribute(@asking?)}
      >
        <label id="agent-prompt-label" for="agent-prompt" class="sr-only">
          Prompt for Allbert
        </label>
        <textarea
          id="agent-prompt"
          name="prompt"
          rows="3"
          class="workspace-composer-input"
          placeholder={@prompt_placeholder}
          aria-labelledby="agent-prompt-label"
          aria-describedby="agent-prompt-counter"
          phx-hook="ComposerEnter"
          data-submit-form="agent-form"
          maxlength={@composer_max_bytes}
        ><%= @prompt %></textarea>

        <div class="workspace-composer-footer">
          <span class="workspace-composer-hint">Enter submits. Shift+Enter adds a line.</span>
          <span
            id="agent-prompt-counter"
            class="workspace-composer-counter workspace-mono"
            data-near-limit={bool_attribute(composer_near_limit?(@prompt, @composer_max_bytes))}
            aria-live="polite"
          >
            {composer_counter_text(@prompt, @composer_max_bytes)}
          </span>
          <div class="workspace-composer-actions">
            <label
              :if={@image_input_upload}
              id="image-input-label"
              class={[
                "workspace-button workspace-button-secondary workspace-image-button",
                (!image_input_enabled?(@image_input) or @asking?) && "workspace-button-disabled"
              ]}
              aria-disabled={bool_attribute(!image_input_enabled?(@image_input) or @asking?)}
              title={image_input_label(@image_input)}
            >
              <.icon name="hero-photo-micro" class="size-4" />
              <span>Image</span>
              <.live_file_input
                upload={@image_input_upload}
                class="workspace-image-file-input"
                disabled={!image_input_enabled?(@image_input) or @asking?}
              />
            </label>
            <button
              id="voice-capture-request"
              type="button"
              class="workspace-button workspace-button-secondary workspace-voice-button"
              phx-click="request_voice_capture"
              disabled={@asking? or voice_capture_pending?(@voice_capture)}
              aria-disabled={bool_attribute(@asking? or voice_capture_pending?(@voice_capture))}
              aria-pressed={bool_attribute(voice_capture_ready?(@voice_capture))}
              aria-label={voice_capture_request_label(@voice_capture)}
              title={voice_capture_request_label(@voice_capture)}
            >
              <.icon name="hero-microphone-micro" class="size-4" />
              <span>{voice_capture_request_text(@voice_capture)}</span>
            </button>
          </div>
          <button
            id="agent-submit"
            type="submit"
            class="workspace-button workspace-button-primary"
            disabled={@asking?}
            aria-disabled={bool_attribute(@asking?)}
            phx-disable-with="Thinking"
          >
            <.icon name="hero-paper-airplane-micro" class="size-4" />
            {if @asking?, do: "Thinking", else: "Ask"}
          </button>
        </div>
      </form>

      <div
        :if={@image_input_upload && @image_input_upload.entries != []}
        id="image-input-uploads"
        class="workspace-image-uploads"
        aria-live="polite"
      >
        <div
          :for={entry <- @image_input_upload.entries}
          class="workspace-image-upload-entry"
          data-upload-ref={entry.ref}
        >
          <.live_img_preview entry={entry} class="workspace-image-preview" />
          <div class="workspace-image-upload-body">
            <span>{entry.client_name}</span>
            <progress value={entry.progress} max="100">{entry.progress}%</progress>
            <p
              :for={err <- upload_errors(@image_input_upload, entry)}
              class="workspace-image-upload-error"
            >
              {image_upload_error(err)}
            </p>
          </div>
          <button
            type="button"
            class="allbert-icon-button"
            phx-click="cancel_image_input_upload"
            phx-value-ref={entry.ref}
            aria-label="Cancel image input upload"
            title="Cancel image input upload"
          >
            <.icon name="hero-x-mark-micro" class="size-4" />
          </button>
        </div>

        <p
          :for={err <- upload_errors(@image_input_upload)}
          class="workspace-image-upload-error"
        >
          {image_upload_error(err)}
        </p>
      </div>

      <form
        :if={voice_capture_ready?(@voice_capture) and @voice_capture_upload}
        id="voice-capture-form"
        phx-change="validate_voice_capture"
        phx-submit="submit_voice_capture"
        class="workspace-voice-capture"
        phx-hook="WorkspaceVoiceCapture"
        data-capture-id={voice_capture_value(@voice_capture, :capture_id)}
        data-capture-resource={voice_capture_value(@voice_capture, :resource_uri)}
        data-max-duration-ms={voice_capture_value(@voice_capture, :max_duration_ms) || 300_000}
        aria-labelledby="voice-capture-title"
      >
        <div class="workspace-voice-capture-header">
          <div>
            <p id="voice-capture-title" class="workspace-voice-capture-title">Voice</p>
            <p
              id="voice-capture-status"
              class="workspace-voice-capture-status"
              data-voice-status
              aria-live="polite"
            >
              Ready
            </p>
          </div>
          <code class="workspace-mono">
            {voice_capture_value(@voice_capture, :resource_uri)}
          </code>
        </div>

        <.live_file_input
          upload={@voice_capture_upload}
          class="workspace-voice-file-input"
          data-voice-file-input
        />

        <div class="workspace-voice-capture-actions">
          <button
            id="voice-capture-start"
            type="button"
            class="workspace-button workspace-button-secondary"
            data-voice-start
            aria-label="Start voice capture"
          >
            <.icon name="hero-microphone-micro" class="size-4" />
            <span>Record</span>
          </button>
          <button
            id="voice-capture-stop"
            type="button"
            class="workspace-button workspace-button-danger"
            data-voice-stop
            disabled
            aria-disabled="true"
            aria-label="Stop voice capture"
          >
            <.icon name="hero-stop-mini" class="size-4" />
            <span>Stop</span>
          </button>
          <button
            id="voice-capture-submit"
            type="submit"
            class="workspace-button workspace-button-primary"
            disabled={@voice_capture_upload.entries == []}
            aria-disabled={bool_attribute(@voice_capture_upload.entries == [])}
          >
            <.icon name="hero-paper-airplane-micro" class="size-4" />
            <span>Send</span>
          </button>
        </div>

        <div
          :for={entry <- @voice_capture_upload.entries}
          class="workspace-voice-upload-entry"
          data-upload-ref={entry.ref}
        >
          <span>{entry.client_name}</span>
          <progress value={entry.progress} max="100">{entry.progress}%</progress>
          <button
            type="button"
            class="allbert-icon-button"
            phx-click="cancel_voice_capture_upload"
            phx-value-ref={entry.ref}
            aria-label="Cancel voice capture upload"
            title="Cancel voice capture upload"
          >
            <.icon name="hero-x-mark-micro" class="size-4" />
          </button>
          <p
            :for={err <- upload_errors(@voice_capture_upload, entry)}
            class="workspace-voice-upload-error"
          >
            {voice_upload_error(err)}
          </p>
        </div>

        <p
          :for={err <- upload_errors(@voice_capture_upload)}
          class="workspace-voice-upload-error"
        >
          {voice_upload_error(err)}
        </p>
      </form>

      <%= if @approval_handoff do %>
        <div
          id="approval-handoff-overlay"
          class="workspace-approval-overlay"
          data-state="open"
          aria-hidden="false"
        >
          <section
            id="approval-handoff"
            class="workspace-approval-inline workspace-approval-modal"
            role="dialog"
            aria-modal="true"
            aria-labelledby="approval-title"
            aria-describedby="approval-confirmation"
            phx-hook="FocusTrap"
            tabindex="-1"
          >
            <div>
              <p class="workspace-approval-eyebrow">Approval Required</p>
              <h2 id="approval-title" class="workspace-card-title">
                {approval_target_summary(@approval_handoff, @approval_lines)}
              </h2>
              <p
                id="approval-confirmation"
                class="workspace-card-summary workspace-mono workspace-copy-target"
                phx-hook="CopyToClipboard"
                data-copy-value={approval_confirmation_id(@approval_handoff)}
                role="button"
                tabindex="0"
                title="Copy confirmation id"
              >
                {approval_confirmation_id(@approval_handoff)}
              </p>
            </div>

            <ul class="workspace-approval-lines">
              <li :for={line <- @approval_lines}>{line}</li>
            </ul>

            <div class="workspace-approval-actions">
              <button
                id="approval-details"
                type="button"
                phx-click="toggle_approval_details"
                class="workspace-button workspace-button-secondary"
                aria-controls="approval-details-data"
                aria-expanded={bool_attribute(@show_approval_details?)}
              >
                {if @show_approval_details?, do: "Hide details", else: "Details"}
              </button>
              <button
                id="approval-deny"
                type="button"
                phx-click="deny_confirmation"
                phx-value-id={approval_confirmation_id(@approval_handoff)}
                class="workspace-button workspace-button-danger"
                phx-disable-with="Denying"
              >
                Deny
              </button>
              <button
                id="approval-approve"
                type="button"
                phx-click="approve_confirmation"
                phx-value-id={approval_confirmation_id(@approval_handoff)}
                class="workspace-button workspace-button-primary"
                phx-disable-with="Approving"
              >
                Approve
              </button>
            </div>

            <pre
              :if={@show_approval_details?}
              id="approval-details-data"
              class="workspace-approval-details"
            ><%= approval_detail_text(@approval_lines) %></pre>
          </section>
        </div>
      <% end %>

      <%= if @approval_result do %>
        <section id="approval-result" class="workspace-status-callout">
          <span>{@approval_result}</span>
        </section>
      <% end %>

      <%= if @error do %>
        <section id="agent-error" class="workspace-error-callout">
          <span>{@error}</span>
        </section>
      <% end %>
    </section>
    """
  end

  defp bool_attribute(true), do: "true"
  defp bool_attribute(false), do: "false"

  defp unified_history_messages(%{messages: messages}) when is_list(messages), do: messages
  defp unified_history_messages(_history), do: []

  defp unified_history_channels(%{channels: channels}) when is_list(channels), do: channels
  defp unified_history_channels(_history), do: []

  defp voice_capture_ready?(capture) do
    voice_capture_value(capture, :status) in [:approved, "approved"] and
      is_binary(voice_capture_value(capture, :resource_uri))
  end

  defp voice_capture_pending?(capture),
    do: voice_capture_value(capture, :status) in [:pending, "pending"]

  defp voice_capture_request_text(capture) do
    cond do
      voice_capture_pending?(capture) -> "Pending"
      voice_capture_ready?(capture) -> "Ready"
      true -> "Mic"
    end
  end

  defp voice_capture_request_label(capture) do
    cond do
      voice_capture_pending?(capture) -> "Microphone capture pending confirmation"
      voice_capture_ready?(capture) -> "Microphone capture approved"
      true -> "Request microphone capture"
    end
  end

  defp voice_capture_value(capture, key) when is_map(capture) do
    Map.get(capture, key) || Map.get(capture, Atom.to_string(key))
  end

  defp voice_capture_value(_capture, _key), do: nil

  defp image_input_enabled?(image_input) do
    image_input_value(image_input, :enabled?) == true
  end

  defp image_input_label(image_input) do
    if image_input_enabled?(image_input) do
      "Attach image input"
    else
      "Vision input disabled"
    end
  end

  defp image_input_value(image_input, key) when is_map(image_input) do
    Map.get(image_input, key) || Map.get(image_input, Atom.to_string(key))
  end

  defp image_input_value(_image_input, _key), do: nil

  defp image_upload_error(:too_large), do: "Too large"
  defp image_upload_error(:too_many_files), do: "One file only"
  defp image_upload_error(:not_accepted), do: "Unsupported type"
  defp image_upload_error(error), do: inspect(error)

  defp voice_upload_error(:too_large), do: "Too large"
  defp voice_upload_error(:too_many_files), do: "One file only"
  defp voice_upload_error(:not_accepted), do: "Unsupported type"
  defp voice_upload_error(error), do: inspect(error)

  defp prompt_present?(prompt) when is_binary(prompt), do: String.trim(prompt) != ""
  defp prompt_present?(_prompt), do: false

  defp maximize_label("chat", maximized) do
    if maximized == "chat", do: "Restore split view", else: "Maximize chat"
  end

  defp maximize_label(_pane, _maximized), do: "Maximize pane"

  defp message_id(%{id: id}) when is_binary(id), do: id
  defp message_id(_message), do: System.unique_integer([:positive])

  defp message_class(message), do: "workspace-message-#{message_role(message)}"

  defp message_avatar(message) do
    case message_role(message) do
      "assistant" -> "A"
      _role -> "You"
    end
  end

  defp message_label(message) do
    case message_role(message) do
      "assistant" -> "Allbert"
      _role -> "You"
    end
  end

  defp message_role(%{role: role}) when is_binary(role) do
    if role == "assistant", do: "assistant", else: "user"
  end

  defp message_role(_message), do: "user"

  defp message_content(%{content: content}) when is_binary(content), do: content
  defp message_content(_message), do: ""

  defp message_media_outputs(message) do
    message
    |> message_metadata()
    |> metadata_value(:media_outputs)
    |> case do
      outputs when is_list(outputs) -> Enum.filter(outputs, &is_map/1)
      _other -> []
    end
  end

  defp message_metadata(%{metadata: metadata}) when is_map(metadata), do: metadata
  defp message_metadata(_message), do: %{}

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_value(_metadata, _key), do: nil

  defp media_output_kind(output) do
    case metadata_value(output, :kind) do
      kind when kind in [:image, "image"] -> "image"
      kind when kind in [:audio, "audio"] -> "audio"
      _kind -> "unknown"
    end
  end

  defp media_output_src(message, index), do: ~p"/workspace/media/#{message_id(message)}/#{index}"

  defp media_output_alt(output) do
    case metadata_value(output, :filename) do
      filename when is_binary(filename) and filename != "" -> "Generated image #{filename}"
      _filename -> "Generated image"
    end
  end

  defp media_output_label(output) do
    [
      media_output_kind(output),
      metadata_value(output, :mime_type),
      metadata_value(output, :source_action)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" · ")
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp message_time(%{inserted_at: %DateTime{} = inserted_at}) do
    DateTime.to_iso8601(inserted_at)
  end

  defp message_time(_message), do: nil

  defp show_runtime_response?(_messages, response) when response in [nil, ""], do: false

  defp show_runtime_response?(messages, response) do
    !Enum.any?(messages, &(message_role(&1) == "assistant" and message_content(&1) == response))
  end

  defp latest_assistant_message_id(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(&(message_role(&1) == "assistant"))
    |> case do
      nil -> nil
      message -> message_id(message)
    end
  end

  defp latest_assistant_message_id(_messages), do: nil

  defp timeline_message_dom_id(message, latest_assistant_id) do
    if message_id(message) == latest_assistant_id and message_role(message) == "assistant" do
      "agent-response"
    else
      "workspace-message-#{message_id(message)}"
    end
  end

  defp relative_time(iso_string) when is_binary(iso_string) do
    with {:ok, dt, _offset} <- DateTime.from_iso8601(iso_string) do
      relative_time_string(DateTime.utc_now(), dt)
    else
      _error -> iso_string
    end
  end

  defp relative_time(_value), do: ""

  defp relative_time_string(now, then) do
    diff = DateTime.diff(now, then, :second)

    cond do
      diff < 0 -> Calendar.strftime(then, "%H:%M")
      diff < 10 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> Calendar.strftime(then, "%b %d %H:%M")
    end
  end

  defp approval_confirmation_id(handoff) when is_map(handoff) do
    Map.get(handoff, :confirmation_id) || Map.get(handoff, "confirmation_id")
  end

  defp approval_confirmation_id(_handoff), do: nil

  defp approval_detail_text(lines) when is_list(lines) do
    lines
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> case do
      [] -> "No additional approval details."
      details -> Enum.join(details, "\n")
    end
  end

  defp approval_detail_text(_lines), do: "No additional approval details."

  # v0.26a M32: derive a short human-readable target summary for the modal
  # title — operators want to see WHAT they are approving before reading the
  # full approval lines. Falls back to the first approval line, then to a
  # neutral phrase if nothing is available yet.
  defp approval_target_summary(handoff, lines) do
    Map.get(handoff || %{}, :target) ||
      Map.get(handoff || %{}, "target") ||
      first_line(lines) ||
      "Approve runtime action"
  end

  defp first_line([]), do: nil
  defp first_line([first | _rest]), do: to_string(first)
  defp first_line(_lines), do: nil

  defp composer_byte_length(prompt) when is_binary(prompt), do: byte_size(prompt)
  defp composer_byte_length(_prompt), do: 0

  defp composer_counter_text(prompt, max_bytes) when is_integer(max_bytes) do
    used = composer_byte_length(prompt)
    "#{used} / #{max_bytes}"
  end

  defp composer_counter_text(prompt, _max_bytes), do: "#{composer_byte_length(prompt)}"

  defp composer_near_limit?(prompt, max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    composer_byte_length(prompt) >= div(max_bytes * 9, 10)
  end

  defp composer_near_limit?(_prompt, _max_bytes), do: false
end
