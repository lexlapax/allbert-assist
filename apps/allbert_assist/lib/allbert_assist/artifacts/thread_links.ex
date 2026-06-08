defmodule AllbertAssist.Artifacts.ThreadLinks do
  @moduledoc """
  User-scoped artifact provenance links for thread and message lookup.

  This module owns the Repo-backed edge. The artifact object store remains
  content-addressed file storage under Allbert Home.
  """

  import Ecto.Query

  alias AllbertAssist.Artifacts.ThreadLink
  alias AllbertAssist.Artifacts.Store
  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.Message
  alias AllbertAssist.Repo
  alias AllbertAssist.Resources.ResourceURI

  @roles ~w[created_by referenced_by]

  @doc "Record a created-by edge from `context.request` when thread context exists."
  @spec record_created(String.t(), map(), keyword()) ::
          {:ok, ThreadLink.t() | nil} | {:error, term()}
  def record_created(sha256, context, opts \\ []) do
    record(sha256, context, "created_by", opts)
  end

  @doc "Record a referenced-by edge from `context.request` when thread context exists."
  @spec record_referenced(String.t(), map(), keyword()) ::
          {:ok, ThreadLink.t() | nil} | {:error, term()}
  def record_referenced(sha256, context, opts \\ []) do
    record(sha256, context, "referenced_by", opts)
  end

  @doc "Return bounded provenance metadata suitable for an artifact sidecar."
  @spec provenance_metadata(map(), String.t() | atom()) :: map()
  def provenance_metadata(context, role \\ "created_by")

  def provenance_metadata(context, role) when is_map(context) do
    with {:ok, request} <- request_context(context),
         {:ok, role} <- normalize_role(role) do
      request
      |> resolve_message()
      |> metadata(role)
    else
      _reason -> %{}
    end
  end

  def provenance_metadata(_context, _role), do: %{}

  @doc "Add bounded originating thread/message metadata to a metadata map."
  @spec put_provenance(map(), map(), String.t() | atom()) :: map()
  def put_provenance(metadata, context, role \\ "created_by") when is_map(metadata) do
    case provenance_metadata(context, role) do
      provenance when map_size(provenance) > 0 ->
        Map.update(metadata, :provenance, %{"artifact_thread" => provenance}, fn existing ->
          existing
          |> normalize_metadata_map()
          |> Map.put("artifact_thread", provenance)
        end)

      _empty ->
        metadata
    end
  end

  @doc "Return links for artifacts connected to a user-owned thread."
  @spec list_for_thread(String.t(), String.t(), keyword()) ::
          {:ok, [ThreadLink.t()]} | {:error, term()}
  def list_for_thread(user_id, thread_id, opts \\ []) do
    with {:ok, user_id} <- normalize_required(user_id, :missing_user_id),
         {:ok, thread_id} <- normalize_required(thread_id, :missing_thread_id),
         {:ok, role} <- maybe_role(Keyword.get(opts, :role)) do
      query =
        from link in ThreadLink,
          where: link.user_id == ^user_id and link.thread_id == ^thread_id,
          order_by: [desc: link.inserted_at, asc: link.artifact_sha256, asc: link.id]

      query
      |> maybe_filter_role(role)
      |> Repo.all()
      |> then(&{:ok, &1})
    end
  end

  @doc "Return unique artifact hashes connected to a user-owned thread."
  @spec artifact_sha256s_for_thread(String.t(), String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def artifact_sha256s_for_thread(user_id, thread_id, opts \\ []) do
    with {:ok, links} <- list_for_thread(user_id, thread_id, opts) do
      links
      |> Enum.map(& &1.artifact_sha256)
      |> Enum.uniq()
      |> then(&{:ok, &1})
    end
  end

  @doc "Return user-scoped thread links for one artifact SHA-256."
  @spec list_for_artifact(String.t(), String.t(), keyword()) ::
          {:ok, [ThreadLink.t()]} | {:error, term()}
  def list_for_artifact(user_id, sha256, opts \\ []) do
    with {:ok, user_id} <- normalize_required(user_id, :missing_user_id),
         :ok <- validate_sha256(sha256),
         {:ok, role} <- maybe_role(Keyword.get(opts, :role)) do
      query =
        from link in ThreadLink,
          where: link.user_id == ^user_id and link.artifact_sha256 == ^sha256,
          order_by: [desc: link.inserted_at, asc: link.thread_id, asc: link.id]

      query
      |> maybe_filter_role(role)
      |> Repo.all()
      |> then(&{:ok, &1})
    end
  end

  @doc "Return a trace-safe/public map for one link."
  @spec public_link(ThreadLink.t()) :: map()
  def public_link(%ThreadLink{} = link) do
    %{
      id: link.id,
      sha256: link.artifact_sha256,
      artifact_sha256: link.artifact_sha256,
      artifact_uri: ResourceURI.artifact!(link.artifact_sha256),
      thread_id: link.thread_id,
      message_id: link.message_id,
      role: link.role,
      user_id: link.user_id,
      metadata: link.metadata,
      inserted_at: datetime(link.inserted_at),
      updated_at: datetime(link.updated_at)
    }
  end

  defp record(sha256, context, role, _opts) do
    with :ok <- validate_sha256(sha256),
         {:ok, role} <- normalize_role(role),
         {:ok, request} <- request_context(context) do
      request = resolve_message(request)
      attrs = attrs(sha256, request, role)

      %ThreadLink{}
      |> ThreadLink.changeset(attrs)
      |> Repo.insert(on_conflict: :nothing)
      |> case do
        {:ok, %ThreadLink{id: id} = link} -> {:ok, Repo.get(ThreadLink, id) || link}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :missing_user_id} -> {:ok, nil}
      {:error, :missing_thread_id} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attrs(sha256, request, role) do
    metadata = metadata(request, role)

    %{
      id: link_id(sha256, request, role),
      artifact_sha256: sha256,
      thread_id: request.thread_id,
      message_id: request.message_id,
      role: role,
      user_id: request.user_id,
      metadata: metadata
    }
  end

  defp metadata(request, role) do
    %{
      "thread_id" => request.thread_id,
      "message_id" => request.message_id,
      "input_signal_id" => request.input_signal_id,
      "session_id" => request.session_id,
      "user_id" => request.user_id,
      "role" => role
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp request_context(context) when is_map(context) do
    request = value(context, :request, %{}) || %{}

    with {:ok, user_id} <-
           normalize_required(
             value(request, :user_id) ||
               value(context, :user_id) ||
               value(request, :operator_id) ||
               value(context, :operator_id) ||
               value(context, :actor),
             :missing_user_id
           ),
         {:ok, thread_id} <-
           normalize_required(
             value(request, :thread_id) || value(context, :thread_id),
             :missing_thread_id
           ) do
      {:ok,
       %{
         user_id: user_id,
         thread_id: thread_id,
         input_signal_id: normalize_optional(value(request, :input_signal_id)),
         session_id: normalize_optional(value(request, :session_id)),
         message_id: nil
       }}
    end
  end

  defp request_context(_context), do: {:error, :missing_thread_id}

  defp resolve_message(%{input_signal_id: input_signal_id} = request)
       when is_binary(input_signal_id) and input_signal_id != "" do
    case Conversations.get_message_by_input_signal(
           request.user_id,
           request.thread_id,
           input_signal_id
         ) do
      {:ok, %Message{id: message_id}} -> %{request | message_id: message_id}
      {:error, _reason} -> request
    end
  end

  defp resolve_message(request), do: request

  defp link_id(sha256, request, role) do
    message_key = request.message_id || request.input_signal_id || "thread"
    edge = Enum.join([sha256, request.user_id, request.thread_id, message_key, role], <<0>>)

    digest =
      :crypto.hash(:sha256, edge)
      |> Base.encode16(case: :lower)

    "artlink_" <> digest
  end

  defp maybe_filter_role(query, nil), do: query
  defp maybe_filter_role(query, role), do: from(link in query, where: link.role == ^role)

  defp maybe_role(nil), do: {:ok, nil}
  defp maybe_role(""), do: {:ok, nil}
  defp maybe_role(role), do: normalize_role(role)

  defp normalize_role(role) when is_atom(role), do: role |> Atom.to_string() |> normalize_role()

  defp normalize_role(role) when is_binary(role) do
    normalized = role |> String.trim() |> String.downcase()

    if normalized in @roles, do: {:ok, normalized}, else: {:error, :invalid_artifact_thread_role}
  end

  defp normalize_role(_role), do: {:error, :invalid_artifact_thread_role}

  defp validate_sha256(sha256) do
    if Store.valid_sha256?(sha256), do: :ok, else: {:error, :invalid_sha256}
  end

  defp normalize_required(value, error) do
    case normalize_optional(value) do
      nil -> {:error, error}
      value -> {:ok, value}
    end
  end

  defp normalize_optional(nil), do: nil

  defp normalize_optional(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp normalize_metadata_map(%{} = map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp normalize_metadata_map(_value), do: %{}

  defp value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp datetime(nil), do: nil
  defp datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp datetime(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)
end
