defmodule AllbertAssist.Projection.PromoteProtocol do
  @moduledoc """
  Fixed-file SQLite generation promotion shared by Memory and Search owners.

  This module owns only the failure-sensitive promotion sequence. Domain
  schemas, rebuild sources, generation metadata, verification queries, reader
  admission, and process state remain with the calling projection owner.
  """

  alias Exqlite.Sqlite3

  @generation_pattern ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  @type connection :: term()
  @type state :: %{
          serving_conn: connection() | nil,
          builder_conn: connection() | nil,
          current_path: String.t(),
          previous_path: String.t(),
          builder_path: String.t()
        }

  @doc "Run the fixed checkpoint, proof, quiesce, swap, and verified-reopen sequence."
  @spec promote(keyword()) :: {:ok, state()} | {:error, term(), state()}
  def promote(opts) when is_list(opts) do
    with {:ok, inputs} <- inputs(opts),
         :ok <- checkpoint_truncate(inputs.builder_conn) do
      promote_checkpointed(inputs)
    else
      {:error, reason} -> invalid_or_checkpoint_error(opts, reason)
    end
  end

  def promote(_opts), do: {:error, :invalid_promote_options, empty_state()}

  defp promote_checkpointed(inputs) do
    case close(inputs.builder_conn) do
      :ok ->
        closed = %{inputs | builder_conn: nil}

        with :ok <- remove_sidecars(closed.builder_path),
             :ok <- prove_self_contained(closed.builder_path, closed.verify),
             :ok <- closed.quiesce.() do
          promote_quiesced(closed)
        else
          {:error, reason} -> {:error, reason, public_state(closed)}
          other -> {:error, {:invalid_quiesce_result, other}, public_state(closed)}
        end

      {:error, reason} ->
        {:error, {:builder_close_failed, reason}, public_state(inputs)}
    end
  end

  defp promote_quiesced(inputs) do
    case close(inputs.serving_conn) do
      :ok ->
        closed = %{inputs | serving_conn: nil}

        case swap_in_builder(closed) do
          :ok -> reopen_promoted(closed)
          {:error, reason} -> reopen_unswapped(closed, reason)
        end

      {:error, reason} ->
        {:error, {:serving_close_failed, reason}, public_state(inputs)}
    end
  end

  defp reopen_promoted(inputs) do
    case open_verified(inputs.current_path, inputs.verify) do
      {:ok, serving_conn} -> {:ok, public_state(%{inputs | serving_conn: serving_conn})}
      {:error, reason} -> rollback_swapped(inputs, reason)
    end
  end

  defp reopen_unswapped(inputs, promotion_error) do
    case reopen_if_present(inputs.current_path, inputs.verify) do
      {:ok, serving_conn} ->
        {:error, promotion_error, public_state(%{inputs | serving_conn: serving_conn})}

      {:error, reopen_error} ->
        {:error, {:promotion_and_reopen_failed, promotion_error, reopen_error},
         public_state(inputs)}
    end
  end

  defp swap_in_builder(inputs) do
    with :ok <- remove_database(inputs.previous_path),
         :ok <- remove_sidecars(inputs.current_path),
         {:ok, current_moved?} <- move_current_to_previous(inputs) do
      case rename(inputs.builder_path, inputs.current_path) do
        :ok -> :ok
        {:error, reason} -> restore_unswapped_current(inputs, current_moved?, reason)
      end
    end
  end

  defp move_current_to_previous(inputs) do
    if File.exists?(inputs.current_path),
      do: with(:ok <- rename(inputs.current_path, inputs.previous_path), do: {:ok, true}),
      else: {:ok, false}
  end

  defp restore_unswapped_current(inputs, true, promotion_error) do
    case rename(inputs.previous_path, inputs.current_path) do
      :ok -> {:error, promotion_error}
      {:error, reason} -> {:error, {:swap_and_restore_failed, promotion_error, reason}}
    end
  end

  defp restore_unswapped_current(_inputs, false, promotion_error),
    do: {:error, promotion_error}

  defp rollback_swapped(inputs, promotion_error) do
    _ = restore_builder(inputs)

    case restore_current(inputs) do
      {:ok, serving_conn} ->
        {:error, promotion_error, public_state(%{inputs | serving_conn: serving_conn})}

      {:error, rollback_error} ->
        {:error, {:promotion_and_rollback_failed, promotion_error, rollback_error},
         public_state(%{inputs | serving_conn: nil})}
    end
  end

  defp restore_builder(inputs) do
    if File.exists?(inputs.current_path) do
      rename(inputs.current_path, inputs.builder_path)
    else
      :ok
    end
  end

  defp restore_current(inputs) do
    if File.exists?(inputs.previous_path) do
      with :ok <- rename(inputs.previous_path, inputs.current_path),
           {:ok, conn} <- open_verified(inputs.current_path, inputs.verify) do
        {:ok, conn}
      end
    else
      {:ok, nil}
    end
  end

  defp reopen_if_present(path, verify) do
    if File.exists?(path), do: open_verified(path, verify), else: {:ok, nil}
  end

  defp prove_self_contained(path, verify) do
    with {:ok, conn} <- open_verified(path, verify) do
      close(conn)
    end
  end

  defp open_verified(path, verify) do
    case Sqlite3.open(path, mode: :readwrite) do
      {:ok, conn} -> verify_open_connection(conn, path, verify)
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_open_connection(conn, path, verify) do
    result =
      with :ok <- integrity_check(conn),
           :ok <- verify.(conn, path) do
        :ok
      else
        {:error, reason} -> {:error, reason}
        other -> {:error, {:invalid_projection_verifier_result, other}}
      end

    case result do
      :ok -> {:ok, conn}
      {:error, _reason} = error -> close_with_error(conn, error)
    end
  end

  defp close_with_error(conn, error) do
    _ = close(conn)
    error
  end

  defp checkpoint_truncate(conn) do
    case query_one(conn, "PRAGMA wal_checkpoint(TRUNCATE)") do
      {:ok, [0, _log_frames, _checkpointed_frames]} -> :ok
      {:ok, [busy, _log_frames, _checkpointed_frames]} -> {:error, {:checkpoint_busy, busy}}
      {:ok, row} -> {:error, {:invalid_checkpoint_result, row}}
      {:error, reason} -> {:error, {:checkpoint_failed, reason}}
    end
  end

  defp integrity_check(conn) do
    case query_one(conn, "PRAGMA integrity_check") do
      {:ok, ["ok"]} -> :ok
      {:ok, row} -> {:error, {:integrity_check_failed, row}}
      {:error, reason} -> {:error, {:integrity_check_failed, reason}}
    end
  end

  defp query_one(conn, sql) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql) do
      try do
        case Sqlite3.step(conn, statement) do
          {:row, row} -> {:ok, row}
          :done -> {:error, :no_row}
          :busy -> {:error, :busy}
          {:error, reason} -> {:error, reason}
        end
      after
        _ = Sqlite3.release(conn, statement)
      end
    end
  end

  defp inputs(opts) do
    root = opts |> Keyword.get(:root) |> expand_path()
    generation_id = Keyword.get(opts, :generation_id)
    builder_conn = Keyword.get(opts, :builder_conn)
    serving_conn = Keyword.get(opts, :serving_conn)
    verify = Keyword.get(opts, :verify)
    quiesce = Keyword.get(opts, :quiesce)

    with :ok <- validate(is_binary(root), :invalid_projection_root),
         :ok <- validate(valid_generation_id?(generation_id), :invalid_generation_id),
         :ok <- validate(not is_nil(builder_conn), :missing_builder_connection),
         :ok <- validate(is_function(verify, 2), :invalid_projection_verifier),
         :ok <- validate(is_function(quiesce, 0), :invalid_quiesce_callback) do
      {:ok,
       %{
         root: root,
         generation_id: generation_id,
         builder_conn: builder_conn,
         serving_conn: serving_conn,
         verify: verify,
         quiesce: quiesce,
         current_path: Path.join(root, "current.sqlite3"),
         previous_path: Path.join(root, "previous.sqlite3"),
         builder_path: Path.join(root, "build-#{generation_id}.sqlite3")
       }}
    end
  end

  defp invalid_or_checkpoint_error(opts, reason) do
    case inputs(opts) do
      {:ok, inputs} -> {:error, reason, public_state(inputs)}
      {:error, input_error} -> {:error, input_error, empty_state()}
    end
  end

  defp public_state(inputs) do
    Map.take(inputs, [
      :serving_conn,
      :builder_conn,
      :current_path,
      :previous_path,
      :builder_path
    ])
  end

  defp empty_state do
    %{
      serving_conn: nil,
      builder_conn: nil,
      current_path: "",
      previous_path: "",
      builder_path: ""
    }
  end

  defp remove_database(path) do
    with :ok <- remove_file(path),
         :ok <- remove_sidecars(path) do
      :ok
    end
  end

  defp remove_sidecars(path) do
    Enum.reduce_while(["-wal", "-shm"], :ok, fn suffix, :ok ->
      case remove_file(path <> suffix) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp remove_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:file_remove_failed, path, reason}}
    end
  end

  defp rename(from, to) do
    case File.rename(from, to) do
      :ok -> :ok
      {:error, reason} -> {:error, {:file_rename_failed, from, to, reason}}
    end
  end

  defp close(nil), do: :ok
  defp close(conn), do: Sqlite3.close(conn)
  defp expand_path(path) when is_binary(path), do: Path.expand(path)
  defp expand_path(_path), do: nil

  defp valid_generation_id?(value) when is_binary(value),
    do: Regex.match?(@generation_pattern, value)

  defp valid_generation_id?(_value), do: false

  defp validate(true, _reason), do: :ok
  defp validate(false, reason), do: {:error, reason}
end
