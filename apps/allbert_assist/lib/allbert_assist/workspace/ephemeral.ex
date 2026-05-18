defmodule AllbertAssist.Workspace.Ephemeral do
  @moduledoc """
  Plain Ecto-backed store for per-thread ephemeral workspace surfaces.
  """

  import Ecto.Query

  alias AllbertAssist.Repo
  alias AllbertAssist.Settings
  alias AllbertAssist.Workspace.BodyStore
  alias AllbertAssist.Workspace.Ephemeral.Surface

  @default_max_active 16

  @type surface :: Surface.t()

  @spec surfaces_for_thread(String.t(), String.t(), keyword()) ::
          {:ok, [surface()]} | {:error, term()}
  def surfaces_for_thread(thread_id, user_id, opts \\ [])
      when is_binary(thread_id) and is_binary(user_id) do
    include_dismissed? = Keyword.get(opts, :include_dismissed, false)

    Surface
    |> where([surface], surface.thread_id == ^thread_id and surface.user_id == ^user_id)
    |> maybe_active_only(include_dismissed?)
    |> order_by([surface], asc: surface.opened_at)
    |> Repo.all()
    |> load_bodies()
  end

  @spec open(map()) :: {:ok, surface()} | {:error, term()}
  def open(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, attrs} <- put_create_defaults(attrs),
         :ok <- enforce_cap(attrs.user_id, attrs.thread_id),
         :ok <- BodyStore.write_body(attrs.body_yaml_path, attrs.body) do
      %Surface{}
      |> Surface.changeset(Map.delete(attrs, :body))
      |> Repo.insert()
      |> load_body_result()
    end
  end

  def open(_attrs), do: {:error, :invalid_ephemeral_attrs}

  @spec dismiss(String.t(), String.t(), String.t() | atom()) ::
          {:ok, surface()} | {:error, term()}
  def dismiss(surface_id, user_id, dismissed_by \\ "operator")
      when is_binary(surface_id) and is_binary(user_id) do
    with {:ok, surface} <- get_user_surface(surface_id, user_id) do
      surface
      |> Surface.changeset(%{
        dismissed_at: DateTime.utc_now(),
        dismissed_by: normalize_dismissed_by(dismissed_by)
      })
      |> Repo.update()
      |> load_body_result()
    end
  end

  defp get_user_surface(surface_id, user_id) do
    query =
      Surface
      |> where(
        [surface],
        surface.id == ^surface_id and surface.user_id == ^user_id and
          is_nil(surface.dismissed_at)
      )

    case Repo.one(query) do
      %Surface{} = surface -> {:ok, surface}
      nil -> {:error, :not_found}
    end
  end

  defp put_create_defaults(attrs) do
    id = Map.get(attrs, :id) || new_id("eph")
    user_id = required_string(attrs, :user_id)
    thread_id = required_string(attrs, :thread_id)
    kind = attrs |> Map.get(:kind, :ephemeral_surface) |> normalize_kind()

    cond do
      is_nil(user_id) -> {:error, {:missing_required, :user_id}}
      is_nil(thread_id) -> {:error, {:missing_required, :thread_id}}
      true -> {:ok, create_defaults(attrs, id, user_id, thread_id, kind)}
    end
  end

  defp create_defaults(attrs, id, user_id, thread_id, kind) do
    attrs
    |> Map.put(:id, id)
    |> Map.put(:user_id, user_id)
    |> Map.put(:thread_id, thread_id)
    |> Map.put(:kind, kind)
    |> Map.put_new(:pinned, false)
    |> Map.put_new(:metadata, %{})
    |> Map.put_new(:body, %{})
    |> Map.put_new(:opened_at, DateTime.utc_now())
    |> Map.put_new(:body_yaml_path, BodyStore.ephemeral_body_path(user_id, thread_id, id))
  end

  defp enforce_cap(user_id, thread_id) do
    active_count =
      Surface
      |> where(
        [surface],
        surface.user_id == ^user_id and surface.thread_id == ^thread_id and
          is_nil(surface.dismissed_at)
      )
      |> Repo.aggregate(:count, :id)

    if active_count < max_active_per_thread() do
      :ok
    else
      dismiss_oldest_non_pinned(user_id, thread_id)
    end
  end

  defp dismiss_oldest_non_pinned(user_id, thread_id) do
    surface =
      Surface
      |> where(
        [surface],
        surface.user_id == ^user_id and surface.thread_id == ^thread_id and
          is_nil(surface.dismissed_at) and surface.pinned == false
      )
      |> order_by([surface], asc: surface.opened_at)
      |> limit(1)
      |> Repo.one()

    case surface do
      %Surface{} ->
        surface
        |> Surface.changeset(%{
          dismissed_at: DateTime.utc_now(),
          dismissed_by: "cap_evicted"
        })
        |> Repo.update()
        |> case do
          {:ok, _surface} -> :ok
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:error, :ephemeral_cap_exceeded}
    end
  end

  defp load_bodies(surfaces) do
    surfaces
    |> Enum.reduce_while([], fn surface, acc ->
      case load_body(surface) do
        {:ok, loaded} -> {:cont, [loaded | acc]}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      loaded -> {:ok, Enum.reverse(loaded)}
    end
  end

  defp load_body_result({:ok, %Surface{} = surface}), do: load_body(surface)
  defp load_body_result({:error, reason}), do: {:error, reason}

  defp load_body(%Surface{} = surface) do
    with {:ok, body} <- BodyStore.read_body(surface.body_yaml_path) do
      {:ok, %{surface | body: body}}
    end
  end

  defp maybe_active_only(query, true), do: query
  defp maybe_active_only(query, false), do: where(query, [record], is_nil(record.dismissed_at))

  defp max_active_per_thread do
    case Settings.get("workspace.ephemeral.max_active_per_thread") do
      {:ok, value} when is_integer(value) -> value
      _other -> @default_max_active
    end
  end

  defp normalize_attrs(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(key) -> {String.to_atom(key), value}
      pair -> pair
    end)
  end

  defp normalize_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp normalize_kind(kind) when is_binary(kind), do: kind
  defp normalize_kind(kind), do: to_string(kind)

  defp normalize_dismissed_by(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_dismissed_by(value) when is_binary(value), do: value
  defp normalize_dismissed_by(value), do: to_string(value)

  defp required_string(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> value
      value when is_atom(value) -> Atom.to_string(value)
      _other -> nil
    end
  end

  defp new_id(prefix), do: "#{prefix}_#{Ecto.UUID.generate()}"
end
