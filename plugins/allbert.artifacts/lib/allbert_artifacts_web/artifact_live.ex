defmodule AllbertArtifactsWeb.ArtifactLive do
  @moduledoc """
  Plugin-owned Artifacts Browser detail page.

  The page validates SHA-256 route params before action reads, uses only
  registered core artifact actions, and renders redacted metadata. Raw artifact
  bytes are never requested.
  """

  use AllbertAssistWeb, :live_view

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Surface.Node
  alias AllbertAssistWeb.Surface.Renderer, as: SurfaceRenderer
  alias AllbertArtifactsWeb.Live

  @sha_regex ~r/^[a-f0-9]{64}$/

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> Live.assign_context(:artifact_detail)
     |> assign(:sha, nil)
     |> assign(:artifact, nil)
     |> assign(:thread_links, [])
     |> assign(:status, :loading)
     |> assign(:load_error, nil)
     |> assign(:delete_notice, nil)
     |> assign(:delete_error, nil)}
  end

  @impl true
  def handle_params(%{"sha" => sha}, _uri, socket) do
    if valid_sha?(sha) do
      {:noreply, load_artifact(socket, sha)}
    else
      {:noreply,
       socket
       |> assign(:sha, sha)
       |> assign(:status, :invalid)
       |> assign(:load_error, "Invalid artifact SHA.")}
    end
  end

  @impl true
  def handle_event("request_delete", _params, socket) do
    case Runner.run("delete_artifact", %{sha256: socket.assigns.sha}, action_context(socket)) do
      {:ok, %{status: :needs_confirmation, confirmation_id: confirmation_id}} ->
        {:noreply,
         socket
         |> assign(:delete_notice, "Delete requires confirmation #{confirmation_id}.")
         |> assign(:delete_error, nil)}

      {:ok, %{status: :completed}} ->
        {:noreply,
         socket
         |> assign(:status, :deleted)
         |> assign(:delete_notice, "Artifact deleted.")
         |> assign(:delete_error, nil)}

      {:ok, response} ->
        {:noreply,
         socket
         |> assign(:delete_notice, nil)
         |> assign(:delete_error, response_message(response, "Delete request failed."))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main
      id="artifacts-detail"
      class="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6"
      data-active-app={@active_app}
      data-artifact-sha={@sha}
      data-surface={@surface_id}
    >
      <a
        href="#artifact-main-content"
        class="sr-only focus:not-sr-only focus:absolute focus:left-4 focus:top-4 focus:z-50 focus:rounded focus:bg-sky-200 focus:px-3 focus:py-2 focus:text-slate-950"
      >
        Skip to artifact content
      </a>

      <section id="artifact-main-content" class="mx-auto flex max-w-5xl flex-col gap-5">
        <header class="flex flex-col gap-3 border-b border-slate-200 pb-4 md:flex-row md:items-end md:justify-between">
          <div class="min-w-0">
            <p class="text-sm font-semibold uppercase text-slate-500">Artifacts Browser</p>
            <h1 class="break-words text-3xl font-semibold tracking-normal">
              {page_title(@status, @sha)}
            </h1>
          </div>

          <.link
            navigate={~p"/workspace?destination=app:allbert_artifacts"}
            class="inline-flex items-center justify-center rounded border border-slate-300 px-3 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-100 focus:outline-none focus-visible:ring-2 focus-visible:ring-sky-500"
          >
            Workspace panel
          </.link>
        </header>

        <section
          :if={@status in [:invalid, :not_found, :error]}
          class="rounded border border-amber-200 bg-amber-50 p-4 text-amber-950"
        >
          <h2 class="text-base font-semibold">Artifact unavailable</h2>
          <p class="mt-1 break-words text-sm">{@load_error}</p>
        </section>

        <section :if={@delete_notice} class="rounded border border-sky-200 bg-sky-50 p-4 text-sky-950">
          <h2 class="text-base font-semibold">Confirmation queued</h2>
          <p class="mt-1 break-words text-sm">{@delete_notice}</p>
        </section>

        <section
          :if={@delete_error}
          class="rounded border border-rose-200 bg-rose-50 p-4 text-rose-950"
        >
          <h2 class="text-base font-semibold">Delete unavailable</h2>
          <p class="mt-1 break-words text-sm">{@delete_error}</p>
        </section>

        <section
          :if={@status == :loaded}
          id="artifact-detail-surface"
          class="grid gap-4"
          aria-label="Artifact metadata"
        >
          <.live_component
            :for={node <- surface_nodes(@artifact, @thread_links)}
            module={SurfaceRenderer}
            id={"artifact-detail-node-#{node.id}"}
            node={node}
          />

          <div class="flex flex-wrap items-center gap-3">
            <button
              id="artifact-delete-request"
              type="button"
              class="rounded border border-rose-300 px-3 py-2 text-sm font-semibold text-rose-700 hover:bg-rose-50 focus:outline-none focus-visible:ring-2 focus-visible:ring-rose-500"
              phx-click="request_delete"
            >
              Request delete
            </button>
            <p class="text-sm text-slate-500">
              Delete routes through the core confirmation-gated action.
            </p>
          </div>
        </section>
      </section>
    </main>
    """
  end

  defp load_artifact(socket, sha) do
    context = action_context(socket)

    case Runner.run("get_artifact", %{sha256: sha, include_bytes: false}, context) do
      {:ok, %{status: :completed, artifact: artifact}} ->
        links = load_thread_links(sha, context)

        socket
        |> assign(:sha, sha)
        |> assign(:artifact, artifact)
        |> assign(:thread_links, links)
        |> assign(:status, :loaded)
        |> assign(:load_error, nil)

      {:ok, response} ->
        socket
        |> assign(:sha, sha)
        |> assign(:status, status_from_response(response))
        |> assign(:load_error, response_message(response, "Artifact could not be loaded."))
    end
  end

  defp load_thread_links(sha, context) do
    case Runner.run("artifact_threads", %{sha256: sha}, context) do
      {:ok, %{status: :completed, links: links}} when is_list(links) -> links
      _response -> []
    end
  end

  defp surface_nodes(artifact, links) do
    [
      %Node{
        id: "artifact-metadata",
        component: :section,
        props: %{
          title: "Metadata",
          body: metadata_body(artifact),
          status: metadata_value(artifact.metadata, :lifecycle, "active")
        }
      },
      %Node{
        id: "artifact-provenance",
        component: :section,
        props: %{
          title: "Provenance",
          body: provenance_body(links),
          status: if(links == [], do: "unlinked", else: "linked")
        }
      }
    ]
  end

  defp metadata_body(%{sha256: sha256, artifact_uri: artifact_uri, metadata: metadata}) do
    [
      "sha=#{sha256}",
      "uri=#{artifact_uri}",
      "mime=#{metadata_value(metadata, :mime, "unknown")}",
      "bytes=#{metadata_value(metadata, :byte_size, "unknown")}",
      "origin=#{metadata_value(metadata, :origin, "unknown")}",
      "retention=#{metadata_value(metadata, :retention, "unknown")}",
      "lifecycle=#{metadata_value(metadata, :lifecycle, "unknown")}",
      "redaction=#{metadata_value(metadata, :redaction_status, "metadata_only")}",
      "created=#{metadata_value(metadata, :created_at, "unknown")}"
    ]
    |> Enum.map(&safe_string/1)
    |> Enum.join(" | ")
  end

  defp provenance_body([]), do: "No thread links recorded."

  defp provenance_body(links) do
    links
    |> Enum.map(fn link ->
      [
        "role=#{link_value(link, :role, "unknown")}",
        "thread=#{link_value(link, :thread_id, "unknown")}",
        "message=#{link_value(link, :message_id, "thread-level")}"
      ]
      |> Enum.map(&safe_string/1)
      |> Enum.join(" | ")
    end)
    |> Enum.join("; ")
  end

  defp action_context(socket) do
    %{
      active_app: :allbert_artifacts,
      user_id: socket.assigns.user_id,
      session_id: socket.assigns.session_id,
      channel: :workspace,
      request: %{
        active_app: :allbert_artifacts,
        user_id: socket.assigns.user_id,
        operator_id: socket.assigns.user_id,
        channel: :workspace,
        source: :artifacts_live
      }
    }
  end

  defp valid_sha?(sha) when is_binary(sha), do: Regex.match?(@sha_regex, sha)
  defp valid_sha?(_sha), do: false

  defp status_from_response(%{error: :not_found}), do: :not_found

  defp status_from_response(%{status: status}) when status in [:denied, :needs_confirmation],
    do: :error

  defp status_from_response(_response), do: :error

  defp response_message(response, fallback) do
    response
    |> Map.get(:message, fallback)
    |> Redactor.redact()
    |> to_string()
  end

  defp page_title(:loaded, sha), do: "Artifact #{String.slice(sha || "", 0, 12)}"
  defp page_title(:deleted, sha), do: "Artifact #{String.slice(sha || "", 0, 12)}"
  defp page_title(:invalid, _sha), do: "Invalid artifact"
  defp page_title(_status, sha) when is_binary(sha), do: "Artifact #{String.slice(sha, 0, 12)}"
  defp page_title(_status, _sha), do: "Artifact"

  defp metadata_value(metadata, key, default) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key)) || default
  end

  defp link_value(link, key, default) when is_map(link) do
    Map.get(link, key) || Map.get(link, Atom.to_string(key)) || default
  end

  defp safe_string(value) do
    value
    |> Redactor.redact()
    |> to_string()
    |> String.replace(~r/\s+/, " ")
  end
end
