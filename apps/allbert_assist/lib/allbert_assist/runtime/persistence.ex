defmodule AllbertAssist.Runtime.Persistence do
  @moduledoc """
  Runtime-facing persistence facade.

  Allbert currently stores durable runtime metadata in SQLite and human-readable
  bodies in YAML under Allbert Home. v0.31 keeps those formats and locations
  stable while giving new runtime, workspace, app, plugin, and future
  sandbox-trial code one persistence entrypoint for shared body operations.
  """

  alias AllbertAssist.Settings.Store, as: SettingsStore
  alias AllbertAssist.Workspace.BodyStore
  alias AllbertAssist.Workspace.Fragment.Body, as: FragmentBody
  alias AllbertAssist.Workspace.Fragment.Envelope

  @type write_error :: BodyStore.write_error()
  @type read_error :: BodyStore.read_error()

  @doc "Return the relative YAML path for a canvas tile body."
  @spec canvas_body_path(String.t(), String.t(), String.t()) :: String.t()
  defdelegate canvas_body_path(user_id, thread_id, tile_id), to: BodyStore

  @doc "Return the relative YAML path for an archived deleted canvas tile body."
  @spec deleted_canvas_body_path(String.t(), DateTime.t()) :: String.t()
  defdelegate deleted_canvas_body_path(relative_path, timestamp), to: BodyStore

  @doc "Return the relative YAML path for an offline canvas revision snapshot."
  @spec canvas_revision_path(String.t(), String.t()) :: String.t()
  defdelegate canvas_revision_path(canvas_body_path, revision_id), to: BodyStore

  @doc "Return the relative YAML path for an ephemeral workspace body."
  @spec ephemeral_body_path(String.t(), String.t(), String.t()) :: String.t()
  defdelegate ephemeral_body_path(user_id, thread_id, surface_id), to: BodyStore

  @doc "Atomically write a workspace YAML body without changing its format."
  @spec write_body(String.t(), map()) :: :ok | {:error, write_error()}
  defdelegate write_body(relative_path, body), to: BodyStore

  @doc "Read a workspace YAML body using the existing body-store semantics."
  @spec read_body(String.t() | nil) :: {:ok, map()} | {:error, read_error()}
  defdelegate read_body(relative_path), to: BodyStore

  @doc "Move a workspace YAML body while preserving current missing-file behavior."
  @spec move(String.t(), String.t()) :: :ok | {:error, {:body_move_failed, atom()}}
  defdelegate move(from_relative, to_relative), to: BodyStore

  @doc "Delete a workspace YAML body while preserving current missing-file behavior."
  @spec delete(String.t()) :: :ok | {:error, {:body_delete_failed, atom()}}
  defdelegate delete(relative_path), to: BodyStore

  @doc "Return the current encoded YAML body size."
  @spec body_size_bytes(map()) :: non_neg_integer()
  defdelegate body_size_bytes(body), to: BodyStore

  @doc "Normalize body values exactly as the existing workspace store does."
  @spec normalize_body(map()) :: map()
  defdelegate normalize_body(body), to: BodyStore

  @doc "Encode a validated workspace fragment envelope body for YAML storage."
  @spec encode_fragment_body(Envelope.t()) :: map()
  defdelegate encode_fragment_body(envelope), to: FragmentBody, as: :encode

  @doc "Recover a Surface tree from a persisted workspace fragment body."
  @spec surface_from_fragment_body(map()) ::
          {:ok, AllbertAssist.Surface.t()} | {:error, :invalid_fragment_body}
  defdelegate surface_from_fragment_body(body), to: FragmentBody, as: :surface_from_body

  @doc "Write arbitrary runtime-owned content atomically to an absolute path."
  @spec write_atomic(String.t(), String.t()) ::
          :ok | {:error, {:settings_write_failed, {term(), term()}}}
  defdelegate write_atomic(path, content), to: SettingsStore
end
