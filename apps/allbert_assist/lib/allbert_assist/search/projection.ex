defmodule AllbertAssist.Search.Projection do
  @moduledoc """
  Single-writer and serving-handle owner for disposable conversation Search.

  This is a plain GenServer because it serializes SQLite writes, reads, and
  fixed-file promotion. Jido lifecycle hooks or Skill composition would not add
  authority or useful state-machine behavior; registered actions remain the
  runtime-facing boundary.
  """

  use GenServer

  alias AllbertAssist.Conversations.Corpus
  alias AllbertAssist.Conversations.SourceEnvelope
  alias AllbertAssist.Jobs.Managed
  alias AllbertAssist.Paths
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Projection.PromoteProtocol
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Search.Control
  alias AllbertAssist.Search.Purge
  alias AllbertAssist.Search.Query
  alias AllbertAssist.Search.Schema
  alias AllbertAssist.Search.SQLite
  alias AllbertAssist.Settings
  alias Exqlite.Sqlite3

  @control_file "control.json"
  @page_size 200
  @ingest_page_size 200
  @reconcile_page_size 100
  @rebuild_pages_per_step 5
  @candidate_batch 100

  defstruct root: nil,
            serving_conn: nil,
            control: nil,
            ready?: false,
            diagnostics: [],
            purge_control: nil,
            bootstrap_jobs?: false,
            effect_guard: EffectGuard,
            effect_guard_opts: []

  @type state :: %__MODULE__{}

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Build, verify, and promote one complete generation from canonical Corpus pages."
  def rebuild(operator_id \\ "local", server \\ __MODULE__),
    do: GenServer.call(server, {:rebuild, operator_id}, :infinity)

  @doc "Resume one bounded managed generation-build step."
  def rebuild_step(operator_id \\ "local", server \\ __MODULE__),
    do: GenServer.call(server, {:rebuild_step, operator_id}, :infinity)

  @doc "Apply one bounded incremental Corpus page per currently granted Search policy."
  def ingest(operator_id \\ "local", server \\ __MODULE__),
    do: GenServer.call(server, {:ingest, operator_id}, :infinity)

  @doc "Run one bounded integrity, FTS-merge, and obsolete-generation maintenance pass."
  def maintain(operator_id \\ "local", server \\ __MODULE__),
    do: GenServer.call(server, {:maintain, operator_id}, :infinity)

  @doc "Return the content-free managed file/generation scope for a purge preview."
  def purge_scope(target, server \\ __MODULE__),
    do: GenServer.call(server, {:purge_scope, target}, :infinity)

  @doc "Begin or continue one exact approved projection purge."
  def purge(params, operator_id, confirmation_id, server \\ __MODULE__),
    do: GenServer.call(server, {:purge, params, operator_id, confirmation_id}, :infinity)

  @doc "Upsert one already-authorized typed Corpus envelope into the current generation."
  def upsert(%SourceEnvelope{} = envelope, server \\ __MODULE__),
    do: GenServer.call(server, {:upsert, envelope}, :infinity)

  @doc "Remove one source from the current disposable generation."
  def delete(source_id, server \\ __MODULE__) when is_binary(source_id),
    do: GenServer.call(server, {:delete, source_id}, :infinity)

  @doc "Return one bounded, locator-only candidate batch for canonical reauthorization."
  def candidates(%Query{} = query, position \\ nil, server \\ __MODULE__),
    do: GenServer.call(server, {:candidates, query, position}, :infinity)

  @doc "Return content-free projection lifecycle status."
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Durably mark stale candidate evidence for the Jobs-owned repair path."
  def queue_repair(reasons, server \\ __MODULE__) when is_list(reasons),
    do: GenServer.cast(server, {:queue_repair, reasons})

  @impl true
  def init(opts) do
    root = opts |> Keyword.get(:root, Paths.search_projection_root()) |> Path.expand()
    File.mkdir_p!(root)
    bootstrap_jobs? = Keyword.get(opts, :bootstrap_jobs?, false)

    case Control.load(root) do
      {:ok, purge_control} ->
        init_with_purge_control(root, purge_control, bootstrap_jobs?, opts)

      {:error, reason} ->
        state = %__MODULE__{
          root: root,
          control: read_control(root),
          diagnostics: [%{code: error_code(reason)}],
          purge_control: :invalid,
          bootstrap_jobs?: bootstrap_jobs?,
          effect_guard: Keyword.get(opts, :effect_guard, EffectGuard),
          effect_guard_opts: Keyword.get(opts, :effect_guard_opts, [])
        }

        {:ok, state}
    end
  end

  @impl true
  def handle_continue(:bootstrap_jobs, state) do
    diagnostics = bootstrap_if_ready(state) ++ state.diagnostics
    {:noreply, %{state | diagnostics: diagnostics}}
  end

  def handle_continue(:resume_purge, state) do
    case with_effect_epoch(state, fn -> continue_purge(state, "local") end) do
      {:ok, _result, next} -> maybe_continue_bootstrap(next)
      {:error, :product_not_ready, next} -> {:noreply, next}
      {:error, reason, next} -> {:noreply, purge_failed(next, reason)}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, status_map(state), state}

  def handle_call({:purge, params, operator_id, confirmation_id}, _from, state) do
    case with_effect_epoch(state, fn ->
           begin_or_continue_purge(state, params, operator_id, confirmation_id)
         end) do
      {:ok, result, next} -> {:reply, {:ok, result}, next}
      {:error, :product_not_ready, next} -> {:reply, {:error, :product_not_ready}, next}
      {:error, reason, next} -> {:reply, {:error, reason}, purge_failed(next, reason)}
    end
  end

  def handle_call(_request, _from, %{purge_control: :invalid} = state),
    do: {:reply, {:error, :search_purge_in_progress}, state}

  def handle_call(_request, _from, %{purge_control: %{"phase" => phase}} = state)
      when phase != "complete",
      do: {:reply, {:error, :search_purge_in_progress}, state}

  def handle_call({:purge_scope, _target}, _from, state),
    do: {:reply, {:ok, purge_scope_map(state)}, state}

  def handle_call({:rebuild, operator_id}, _from, state) do
    case with_effect_epoch(state, fn -> rebuild_generation(state, operator_id) end) do
      {:ok, result, next} -> {:reply, {:ok, result}, next}
      {:error, reason, next} -> {:reply, {:error, reason}, next}
    end
  end

  def handle_call({:rebuild_step, operator_id}, _from, state) do
    case with_effect_epoch(state, fn -> rebuild_generation_step(state, operator_id) end) do
      {:ok, result, next} -> {:reply, {:ok, result}, next}
      {:error, reason, next} -> {:reply, {:error, reason}, next}
    end
  end

  def handle_call({:ingest, operator_id}, _from, %{ready?: true} = state) do
    case with_effect_epoch(state, fn -> ingest_generation(state, operator_id) end) do
      {:ok, result, next} -> {:reply, {:ok, result}, next}
      {:error, reason, next} -> {:reply, {:error, reason}, next}
    end
  end

  def handle_call({:ingest, _operator_id}, _from, state),
    do: {:reply, {:error, :search_not_ready}, state}

  def handle_call({:maintain, operator_id}, _from, %{ready?: true} = state) do
    case with_effect_epoch(state, fn -> maintain_generation(state, operator_id) end) do
      {:ok, result, next} -> {:reply, {:ok, result}, next}
      {:error, reason, next} -> {:reply, {:error, reason}, next}
    end
  end

  def handle_call({:maintain, _operator_id}, _from, state),
    do: {:reply, {:error, :search_not_ready}, state}

  def handle_call({:upsert, envelope}, _from, %{ready?: true} = state) do
    case with_effect_epoch(state, fn ->
           mutate_current(state, fn conn, revision ->
             upsert_envelope(conn, envelope, revision)
           end)
         end) do
      {:ok, result, next} -> {:reply, {:ok, result}, next}
      {:error, reason, next} -> {:reply, {:error, reason}, next}
    end
  end

  def handle_call({:upsert, _envelope}, _from, state),
    do: {:reply, {:error, :search_not_ready}, state}

  def handle_call({:delete, source_id}, _from, %{ready?: true} = state) do
    case with_effect_epoch(state, fn ->
           mutate_current(state, fn conn, revision -> delete_source(conn, source_id, revision) end)
         end) do
      {:ok, result, next} -> {:reply, {:ok, result}, next}
      {:error, reason, next} -> {:reply, {:error, reason}, next}
    end
  end

  def handle_call({:delete, _source_id}, _from, state),
    do: {:reply, {:error, :search_not_ready}, state}

  def handle_call({:candidates, query, position}, _from, %{ready?: true} = state) do
    {:reply, query_candidates(state, query, position), state}
  end

  def handle_call({:candidates, _query, _position}, _from, state),
    do: {:reply, {:error, :search_not_ready}, state}

  @impl true
  def handle_cast({:queue_repair, _reasons}, %{purge_control: :invalid} = state) do
    _ = kick_if_ready(state, "search-index")
    {:noreply, state}
  end

  def handle_cast({:queue_repair, _reasons}, %{purge_control: %{"phase" => phase}} = state)
      when phase != "complete" do
    _ = kick_if_ready(state, "search-index")
    {:noreply, state}
  end

  def handle_cast({:queue_repair, reasons}, state) do
    with {:ok, _epoch} <- ready_epoch(state) do
      safe = reasons |> Enum.map(&error_code/1) |> Enum.uniq() |> Enum.sort()
      control = state.control |> Map.put("dirty", true) |> Map.put("repair_reasons", safe)
      _ = write_control(state.root, control)
      {:noreply, %{state | control: control}}
    else
      {:error, _reason} -> {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    _ = Sqlite3.close(state.serving_conn)
    :ok
  end

  defp init_with_purge_control(root, %{"phase" => "complete"} = purge_control, bootstrap?, opts) do
    {conn, control, diagnostics} = load_generation(root)

    state = %__MODULE__{
      root: root,
      serving_conn: conn,
      control: control,
      ready?: not is_nil(conn),
      diagnostics: diagnostics,
      purge_control: purge_control,
      bootstrap_jobs?: bootstrap?,
      effect_guard: Keyword.get(opts, :effect_guard, EffectGuard),
      effect_guard_opts: Keyword.get(opts, :effect_guard_opts, [])
    }

    if bootstrap?, do: {:ok, state, {:continue, :bootstrap_jobs}}, else: {:ok, state}
  end

  defp init_with_purge_control(root, purge_control, bootstrap?, opts) do
    state = %__MODULE__{
      root: root,
      control: read_control(root),
      diagnostics: [%{code: "search_purge_in_progress"}],
      purge_control: purge_control,
      bootstrap_jobs?: bootstrap?,
      effect_guard: Keyword.get(opts, :effect_guard, EffectGuard),
      effect_guard_opts: Keyword.get(opts, :effect_guard_opts, [])
    }

    {:ok, state, {:continue, :resume_purge}}
  end

  defp maybe_continue_bootstrap(%{bootstrap_jobs?: true} = state),
    do: {:noreply, state, {:continue, :bootstrap_jobs}}

  defp maybe_continue_bootstrap(state), do: {:noreply, state}

  # Every projection mutation and managed-job handoff obtains one readiness
  # epoch at handler entry. The validation immediately preceding the operation
  # deliberately never retries admission, so an E1 -> E2 replacement fails
  # closed instead of executing against E2.
  defp with_effect_epoch(state, fun) do
    with {:ok, _epoch} <- ready_epoch(state) do
      fun.()
    else
      {:error, _reason} -> {:error, :product_not_ready, state}
    end
  end

  defp ready_epoch(state) do
    with {:ok, epoch} <- state.effect_guard.admit_ready(state.effect_guard_opts),
         :ok <- state.effect_guard.validate(epoch, state.effect_guard_opts) do
      {:ok, epoch}
    else
      {:error, _reason} -> {:error, :product_not_ready}
    end
  end

  defp bootstrap_if_ready(state) do
    with {:ok, _epoch} <- ready_epoch(state) do
      bootstrap_managed_jobs(state)
    else
      {:error, _reason} -> [%{code: "product_not_ready"}]
    end
  end

  defp kick_if_ready(state, identity) do
    with {:ok, _epoch} <- ready_epoch(state) do
      Managed.kick(identity, "local")
    else
      {:error, _reason} -> {:error, :product_not_ready}
    end
  end

  defp begin_or_continue_purge(state, params, operator_id, confirmation_id) do
    with {:ok, target} <- Control.normalize_target(params),
         :ok <- Purge.precondition(target, operator_id),
         {:ok, manifest} <-
           Control.begin(state.root, params, purge_scope_map(state), confirmation_id) do
      continue_purge(%{state | purge_control: manifest}, operator_id)
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp continue_purge(%{purge_control: manifest} = state, operator_id) do
    with :ok <- Purge.precondition(purge_target(manifest), operator_id) do
      continue_purge_phase(state, operator_id)
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp continue_purge_phase(%{purge_control: %{"phase" => "pending"}} = state, operator_id) do
    with {:ok, closed} <- close_for_purge(state),
         {:ok, manifest} <-
           Control.transition(
             closed.root,
             closed.purge_control,
             "pending",
             "connections_closed"
           ) do
      continue_purge_phase(%{closed | purge_control: manifest}, operator_id)
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp continue_purge_phase(
         %{purge_control: %{"phase" => "connections_closed"}} = state,
         operator_id
       ) do
    with :ok <- Purge.precondition(purge_target(state.purge_control), operator_id),
         {:ok, replaced} <- replace_purge_files(state, operator_id),
         {:ok, manifest} <-
           Control.transition(
             replaced.root,
             replaced.purge_control,
             "connections_closed",
             "files_replaced"
           ) do
      continue_purge_phase(%{replaced | purge_control: manifest}, operator_id)
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp continue_purge_phase(
         %{purge_control: %{"phase" => "files_replaced"}} = state,
         operator_id
       ) do
    with :ok <- Purge.precondition(purge_target(state.purge_control), operator_id),
         :ok <- verify_purge_files(state),
         {:ok, manifest} <-
           Control.transition(state.root, state.purge_control, "files_replaced", "verified") do
      continue_purge_phase(%{state | purge_control: manifest}, operator_id)
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp continue_purge_phase(%{purge_control: %{"phase" => "verified"}} = state, _operator_id) do
    with {:ok, manifest} <-
           Control.transition(state.root, state.purge_control, "verified", "complete") do
      {conn, control, diagnostics} = load_generation(state.root)
      _ = maybe_kick_after_purge()

      next = %{
        state
        | serving_conn: conn,
          control: control,
          ready?: not is_nil(conn),
          diagnostics: diagnostics,
          purge_control: manifest
      }

      {:ok, purge_result(manifest, next), next}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp continue_purge_phase(%{purge_control: %{"phase" => "complete"}} = state, _operator_id),
    do: {:ok, purge_result(state.purge_control, state), state}

  defp close_for_purge(state) do
    with :ok <- close_connection(state.serving_conn),
         control <-
           state.control
           |> Map.put("state", "not_ready")
           |> Map.put("builder_generation_id", nil)
           |> Map.put("builder", nil)
           |> Map.put("dirty", true),
         :ok <- write_control(state.root, control) do
      {:ok, %{state | serving_conn: nil, control: control, ready?: false}}
    else
      {:error, reason} -> {:error, {:purge_close_failed, reason}}
    end
  end

  defp replace_purge_files(state, operator_id) do
    with :ok <- remove_all_generation_files(state.root),
         :ok <- write_control(state.root, default_control()),
         {:ok, next} <-
           maybe_build_clean_generation(%{state | control: default_control()}, operator_id),
         :ok <- close_connection(next.serving_conn) do
      {:ok, %{next | serving_conn: nil, ready?: false}}
    end
  end

  defp maybe_build_clean_generation(state, operator_id) do
    case setting("search.enabled", true) do
      true ->
        case rebuild_generation(state, operator_id) do
          {:ok, _result, next} ->
            {:ok, next}

          {:error, reason, next} ->
            _ = close_connection(next.serving_conn)
            {:error, {:purge_rebuild_failed, reason}}
        end

      false ->
        {:ok, state}
    end
  end

  defp verify_purge_files(state) do
    databases = database_paths(state.root)
    target = purge_target(state.purge_control)

    with :ok <- expected_database_shape(databases),
         :ok <- each_ok(databases, &verify_purge_database(&1, target)) do
      :ok
    end
  end

  defp expected_database_shape([]), do: :ok

  defp expected_database_shape([path]) do
    if Path.basename(path) == "current.sqlite3",
      do: :ok,
      else: {:error, :unexpected_purge_generation}
  end

  defp expected_database_shape(_paths), do: {:error, :unexpected_purge_generation}

  defp verify_purge_database(path, target) do
    with {:ok, conn} <- Sqlite3.open(path, mode: :readwrite) do
      result =
        with {:ok, _capability} <- Schema.verify(conn),
             :ok <- verify_target_absent(conn, target) do
          :ok
        end

      case close_connection(conn) do
        :ok -> result
        {:error, reason} -> {:error, {:purge_verify_close_failed, reason}}
      end
    end
  end

  defp verify_target_absent(conn, %{"target_kind" => "source_ids", "target_ids" => ids}) do
    placeholders = Enum.map_join(ids, ",", fn _id -> "?" end)

    case SQLite.query_one(
           conn,
           "SELECT COUNT(*) FROM documents WHERE source_id IN (#{placeholders})",
           ids
         ) do
      {:ok, [0]} -> :ok
      {:ok, [_count]} -> {:error, :purge_target_retained}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_target_absent(conn, _target) do
    case SQLite.query_one(conn, "SELECT COUNT(*) FROM documents") do
      {:ok, [0]} -> :ok
      {:ok, [_count]} -> {:error, :purge_target_retained}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_all_generation_files(root) do
    root
    |> managed_database_paths()
    |> each_ok(&remove_file/1)
    |> case do
      :ok -> sync_directory(root)
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:purge_file_remove_failed, Path.basename(path), reason}}
    end
  end

  defp managed_database_paths(root) do
    root
    |> Path.join("*.sqlite3*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
  end

  defp database_paths(root) do
    root
    |> Path.join("*.sqlite3")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
  end

  defp purge_scope_map(state) do
    manifest =
      if is_map(state.purge_control), do: state.purge_control, else: %{"policy_epoch" => 0}

    %{
      eligibility_epoch: Corpus.eligibility_epoch(:search),
      policy_epoch: manifest["policy_epoch"] || 0,
      managed_files:
        state.root
        |> managed_database_paths()
        |> Enum.map(&Path.basename/1),
      generation_ids: generation_ids(state)
    }
  end

  defp generation_ids(state) do
    control_ids =
      ~w[current_generation_id previous_generation_id builder_generation_id]
      |> Enum.map(&state.control[&1])
      |> Enum.filter(&is_binary/1)

    file_ids =
      state.root
      |> database_paths()
      |> Enum.flat_map(fn path ->
        case Regex.run(~r/(?:build|failed|retired|pending-prune)-([0-9a-f-]+)\.sqlite3$/, path) do
          [_, id] -> [id]
          _other -> []
        end
      end)

    (control_ids ++ file_ids) |> Enum.uniq() |> Enum.sort()
  end

  defp purge_target(manifest) do
    Map.take(manifest, ["target_kind", "target_ids", "source_classes"])
  end

  defp purge_result(manifest, state) do
    %{
      phase: :complete,
      target_kind: String.to_existing_atom(manifest["target_kind"]),
      attempt_id: manifest["attempt_id"],
      policy_epoch: manifest["policy_epoch"],
      ready?: state.ready?
    }
  end

  defp purge_failed(state, reason) do
    manifest =
      case state.purge_control do
        %{"phase" => phase} = current when phase != "complete" ->
          case Control.record_error(state.root, current, reason) do
            {:ok, updated} -> updated
            {:error, _record_error} -> current
          end

        other ->
          other
      end

    %{
      state
      | purge_control: manifest,
        diagnostics: [%{code: error_code(reason)} | state.diagnostics]
    }
  end

  defp close_connection(nil), do: :ok
  defp close_connection(conn), do: Sqlite3.close(conn)

  defp maybe_kick_after_purge do
    if setting("search.enabled", true), do: Managed.kick("search-index", "local"), else: :ok
  end

  defp rebuild_generation(state, operator_id) when is_binary(operator_id) do
    with {:ok, snapshots} <- snapshots(operator_id),
         {:ok, primary} <- primary_snapshot(snapshots) do
      build_generation(state, snapshots, primary)
    else
      {:error, reason} -> fail_rebuild(state, reason, nil)
    end
  end

  defp rebuild_generation(state, _operator_id), do: fail_rebuild(state, :invalid_operator, nil)

  defp rebuild_generation_step(state, operator_id) when is_binary(operator_id) do
    with {:ok, prepared} <- ensure_resumable_builder(state, operator_id) do
      run_resumable_builder_step(prepared)
    else
      {:error, reason, next} -> {:error, reason, next}
    end
  end

  defp rebuild_generation_step(state, _operator_id),
    do: {:error, :invalid_operator, mark_dirty(state, :invalid_operator)}

  defp ensure_resumable_builder(state, operator_id) do
    builder = state.control["builder"]

    if compatible_builder?(builder, operator_id, state.root) do
      {:ok, state}
    else
      state
      |> discard_resumable_builder()
      |> start_resumable_builder(operator_id)
    end
  end

  defp start_resumable_builder(state, operator_id) do
    with {:ok, snapshots} <- snapshots(operator_id),
         {:ok, primary} <- primary_snapshot(snapshots) do
      generation_id = uuid7()
      path = builder_path(state.root, generation_id)

      builder = %{
        "generation_id" => generation_id,
        "operator_id" => operator_id,
        "eligibility_epoch" => primary.eligibility_epoch,
        "schema_version" => Schema.schema_version(),
        "tokenizer_version" => Schema.tokenizer_version(),
        "redactor_version" => Schema.redactor_version(),
        "snapshots" => Enum.map(snapshots, &encode_builder_snapshot/1),
        "policy_index" => 0,
        "cursor" => nil,
        "document_count" => 0,
        "projection_revision" => 0
      }

      control =
        state.control
        |> Map.put("builder_generation_id", generation_id)
        |> Map.put("builder", builder)
        |> Map.put("dirty", true)
        |> Map.put("last_error_code", nil)
        |> Map.put("state", if(state.ready?, do: "ready", else: "rebuilding"))

      with :ok <- write_control(state.root, control),
           {:ok, conn} <- Sqlite3.open(path),
           :ok <-
             Schema.create(conn, %{
               generation_id: generation_id,
               eligibility_epoch: primary.eligibility_epoch,
               high_water: primary.high_water
             }),
           :ok <- Sqlite3.close(conn) do
        {:ok, %{state | control: control}}
      else
        {:error, reason} -> {:error, reason, mark_dirty(%{state | control: control}, reason)}
      end
    else
      {:error, reason} -> {:error, reason, mark_dirty(state, reason)}
    end
  end

  defp run_resumable_builder_step(state) do
    builder = state.control["builder"]
    path = builder_path(state.root, builder["generation_id"])

    with {:ok, snapshots} <- decode_builder_snapshots(builder),
         :ok <- current_epochs(snapshots),
         {:ok, conn} <- Sqlite3.open(path, mode: :readwrite) do
      process_resumable_pages(state, conn, snapshots, @rebuild_pages_per_step)
    else
      {:error, reason} -> {:error, reason, mark_dirty(state, reason)}
    end
  end

  defp process_resumable_pages(state, conn, snapshots, pages_left) do
    builder = state.control["builder"]

    cond do
      builder["policy_index"] >= length(snapshots) ->
        finalize_resumable_builder(state, conn, snapshots)

      pages_left == 0 ->
        _ = Sqlite3.close(conn)
        {:ok, resumable_result(state, :incomplete), state}

      true ->
        process_resumable_page(state, conn, snapshots, pages_left)
    end
  end

  defp process_resumable_page(state, conn, snapshots, pages_left) do
    builder = state.control["builder"]
    snapshot = Enum.at(snapshots, builder["policy_index"])
    watermark = decode_source_watermark(builder["cursor"])

    with {:ok, page} <- Corpus.page_after(snapshot, watermark, @page_size),
         {:ok, written} <-
           write_page(conn, page.items, page.cursor, %{
             count: builder["document_count"],
             revision: builder["projection_revision"],
             indexed_through: nil
           }) do
      builder = advance_builder(builder, snapshot, page, written)
      control = Map.put(state.control, "builder", builder)

      with :ok <- write_control(state.root, control) do
        process_resumable_pages(%{state | control: control}, conn, snapshots, pages_left - 1)
      else
        {:error, reason} ->
          _ = Sqlite3.close(conn)
          {:error, reason, mark_dirty(state, reason)}
      end
    else
      {:error, reason} ->
        _ = Sqlite3.close(conn)
        {:error, reason, mark_dirty(state, reason)}
    end
  end

  defp advance_builder(builder, snapshot, page, written) do
    {policy_index, cursor} =
      if page.exhausted? do
        {builder["policy_index"] + 1, nil}
      else
        {builder["policy_index"], encode_source_watermark(cursor_watermark(page.cursor))}
      end

    builder
    |> Map.put("policy_index", policy_index)
    |> Map.put("cursor", cursor)
    |> Map.put("document_count", written.count)
    |> Map.put("projection_revision", written.revision)
    |> Map.put("last_policy_high_water", encode_source_watermark(snapshot.high_water))
  end

  defp finalize_resumable_builder(state, conn, snapshots) do
    builder = state.control["builder"]

    with {:ok, source_advanced?} <- source_advanced?(snapshots),
         {:ok, _capability} <- Schema.verify(conn, builder["generation_id"]),
         {:ok, promoted} <- promote(state, builder["generation_id"], conn) do
      build = %{
        count: builder["document_count"],
        revision: builder["projection_revision"],
        indexed_through: nil,
        source_advanced?: source_advanced?,
        source_cursors: snapshot_high_waters(snapshots)
      }

      case finish_rebuild(state, builder["generation_id"], state.control, build, promoted) do
        {:ok, result, next} -> {:ok, Map.put(result, :status, :complete), next}
        error -> error
      end
    else
      {:error, reason, promoted} ->
        fail_rebuild(state, reason, promoted)

      {:error, reason} ->
        _ = Sqlite3.close(conn)
        {:error, reason, mark_dirty(state, reason)}
    end
  end

  defp resumable_result(state, status) do
    builder = state.control["builder"]

    %{
      status: status,
      generation_id: builder["generation_id"],
      document_count: builder["document_count"],
      projection_revision: builder["projection_revision"],
      policy_index: builder["policy_index"]
    }
  end

  defp compatible_builder?(builder, operator_id, root) when is_map(builder) do
    builder["operator_id"] == operator_id and
      builder["eligibility_epoch"] == Corpus.eligibility_epoch(:search) and
      builder["schema_version"] == Schema.schema_version() and
      builder["tokenizer_version"] == Schema.tokenizer_version() and
      builder["redactor_version"] == Schema.redactor_version() and
      File.regular?(builder_path(root, builder["generation_id"]))
  end

  defp compatible_builder?(_builder, _operator_id, _root), do: false

  defp discard_resumable_builder(state) do
    case state.control["builder_generation_id"] do
      generation_id when is_binary(generation_id) ->
        remove_database(builder_path(state.root, generation_id))

      _other ->
        :ok
    end

    control =
      state.control
      |> Map.put("builder_generation_id", nil)
      |> Map.put("builder", nil)

    _ = write_control(state.root, control)
    %{state | control: control}
  end

  defp builder_path(root, generation_id),
    do: Path.join(root, "build-#{generation_id}.sqlite3")

  defp ingest_generation(state, operator_id) when is_binary(operator_id) do
    with {:ok, _meta} <- generation_meta(state.serving_conn),
         :ok <- current_eligibility_epoch(state.serving_conn),
         {:ok, snapshots} <- snapshots(operator_id),
         {:ok, result, control} <- ingest_snapshots(state, snapshots) do
      :ok = write_control(state.root, control)
      interim = %{state | control: control, diagnostics: []}
      finish_ingest(interim, operator_id, result)
    else
      {:error, reason} -> {:error, reason, mark_dirty(state, reason)}
    end
  end

  defp ingest_generation(state, _operator_id),
    do: {:error, :invalid_operator, mark_dirty(state, :invalid_operator)}

  defp finish_ingest(state, operator_id, result) do
    with {:ok, sweep, next} <- reconcile_stale_rows(state, operator_id) do
      incomplete? = result.status == :incomplete or sweep.status == :incomplete
      control = Map.put(next.control, "dirty", incomplete?)
      :ok = write_control(next.root, control)

      {:ok,
       result
       |> Map.put(:status, if(incomplete?, do: :incomplete, else: :complete))
       |> Map.put(:stale_scanned_count, sweep.scanned_count)
       |> Map.put(:stale_deleted_count, sweep.deleted_count), %{next | control: control}}
    end
  end

  defp current_eligibility_epoch(conn) do
    case SQLite.query_one(
           conn,
           "SELECT eligibility_epoch FROM generation_meta WHERE id = 1"
         ) do
      {:ok, [epoch]} ->
        if epoch == Corpus.eligibility_epoch(:search), do: :ok, else: {:error, :rebuild_required}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ingest_snapshots(state, snapshots) do
    initial = %{
      control: state.control,
      indexed_count: 0,
      pages: 0,
      exhausted?: true
    }

    with {:ok, ingested} <- ingest_each_snapshot(state.serving_conn, snapshots, initial),
         {:ok, source_advanced?} <- source_advanced?(snapshots),
         {:ok, meta} <- generation_meta(state.serving_conn) do
      incomplete? = not ingested.exhausted? or source_advanced?

      control =
        ingested.control
        |> Map.put("dirty", incomplete?)
        |> Map.put("state", "ready")
        |> Map.put("projection_revision", meta.projection_revision)
        |> Map.put("last_error_code", nil)

      {:ok,
       %{
         status: if(incomplete?, do: :incomplete, else: :complete),
         indexed_count: ingested.indexed_count,
         page_count: ingested.pages,
         generation_id: meta.generation_id,
         projection_revision: meta.projection_revision,
         indexed_through: meta.indexed_through,
         source_advanced?: source_advanced?
       }, control}
    end
  end

  defp ingest_each_snapshot(conn, snapshots, initial) do
    Enum.reduce_while(snapshots, {:ok, initial}, fn snapshot, {:ok, acc} ->
      case ingest_snapshot(conn, snapshot, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp ingest_snapshot(conn, snapshot, acc) do
    key = policy_key(snapshot.policy)
    cursors = Map.get(acc.control, "source_cursors", %{})
    watermark = decode_source_watermark(Map.get(cursors, key))

    with {:ok, page} <- Corpus.page_after(snapshot, watermark, @ingest_page_size),
         {:ok, written} <-
           write_page(conn, page.items, page.cursor, %{
             count: 0,
             revision: current_revision(conn),
             indexed_through: nil
           }) do
      cursor = if page.exhausted?, do: snapshot.high_water, else: cursor_watermark(page.cursor)
      cursors = Map.put(cursors, key, encode_source_watermark(cursor))

      {:ok,
       %{
         acc
         | control: Map.put(acc.control, "source_cursors", cursors),
           indexed_count: acc.indexed_count + written.count,
           pages: acc.pages + 1,
           exhausted?: acc.exhausted? and page.exhausted?
       }}
    end
  end

  defp current_revision(conn) do
    case generation_meta(conn) do
      {:ok, meta} -> meta.projection_revision
      {:error, _reason} -> 0
    end
  end

  defp bootstrap_managed_jobs(state) do
    with {:ok, results} <- Managed.reconcile("local"),
         false <- Enum.any?(results, & &1.degraded?),
         identity <- if(state.ready?, do: "search-index", else: "search-rebuild"),
         {:ok, _kick} <- Managed.kick(identity, "local") do
      []
    else
      true -> [%{code: "managed_name_conflict"}]
      {:error, reason} -> [%{code: error_code(reason)}]
    end
  end

  defp maintain_generation(state, operator_id) do
    with :ok <- current_eligibility_epoch(state.serving_conn),
         {:ok, sweep, reconciled} <- reconcile_stale_rows(state, operator_id),
         {:ok, _capability} <- Schema.verify(reconciled.serving_conn),
         :ok <- bounded_fts_merge(reconciled.serving_conn),
         {:ok, _capability} <- Schema.verify(reconciled.serving_conn) do
      pruned_count = prune_obsolete_files(reconciled.root, 10)

      control =
        reconciled.control
        |> Map.put("last_maintained_at_us", System.system_time(:microsecond))
        |> Map.put("last_error_code", nil)

      :ok = write_control(reconciled.root, control)

      {:ok,
       %{
         status: sweep.status,
         integrity: :verified,
         merge_pages: 4,
         pruned_file_count: pruned_count,
         stale_scanned_count: sweep.scanned_count,
         stale_deleted_count: sweep.deleted_count,
         generation_id: control["current_generation_id"],
         projection_revision: control["projection_revision"]
       }, %{reconciled | control: control, diagnostics: []}}
    else
      {:error, reason} -> {:error, reason, mark_dirty(state, reason)}
    end
  end

  defp reconcile_stale_rows(state, operator_id) do
    cursor = state.control["reconcile_cursor_source_id"]

    with {:ok, rows} <- stale_candidate_rows(state.serving_conn, cursor),
         {:ok, invalid_ids} <- invalid_stale_ids(rows, operator_id),
         {:ok, next} <- delete_stale_ids(state, invalid_ids) do
      incomplete? = length(rows) == @reconcile_page_size
      next_cursor = if incomplete?, do: rows |> List.last() |> hd(), else: nil

      control = Map.put(next.control, "reconcile_cursor_source_id", next_cursor)
      :ok = write_control(next.root, control)

      {:ok,
       %{
         status: if(incomplete?, do: :incomplete, else: :complete),
         scanned_count: length(rows),
         deleted_count: length(invalid_ids)
       }, %{next | control: control}}
    end
  end

  defp stale_candidate_rows(conn, nil) do
    SQLite.query(
      conn,
      "SELECT source_id, content_digest, origin_scope, e2ee FROM documents " <>
        "ORDER BY source_id ASC LIMIT ?",
      [@reconcile_page_size]
    )
  end

  defp stale_candidate_rows(conn, cursor) do
    SQLite.query(
      conn,
      "SELECT source_id, content_digest, origin_scope, e2ee FROM documents " <>
        "WHERE source_id > ? ORDER BY source_id ASC LIMIT ?",
      [cursor, @reconcile_page_size]
    )
  end

  defp invalid_stale_ids(rows, operator_id) do
    rows
    |> Enum.group_by(fn [_source_id, _digest, origin_scope, e2ee] -> {origin_scope, e2ee} end)
    |> Enum.reduce_while({:ok, []}, fn {{origin_scope, e2ee}, grouped}, {:ok, invalid} ->
      case authorize_stale_group(grouped, operator_id, origin_scope, e2ee) do
        {:ok, ids} -> {:cont, {:ok, ids ++ invalid}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp authorize_stale_group(grouped, operator_id, origin_scope, e2ee) do
    with {:ok, origin_scope} <- decode_origin_scope(origin_scope) do
      policy = %{consumer: :search, origin_scope: origin_scope, e2ee?: e2ee == 1}

      refs =
        Enum.map(grouped, fn [source_id, digest, _scope, _e2ee] ->
          %{source_id: source_id, content_digest: digest}
        end)

      with {:ok, results} <- Corpus.rehydrate_and_authorize(operator_id, refs, policy) do
        {:ok,
         grouped
         |> Enum.zip(results)
         |> Enum.flat_map(fn
           {[_source_id | _rest], {:ok, _envelope}} -> []
           {[source_id | _rest], {:error, _reason}} -> [source_id]
         end)}
      end
    end
  end

  defp delete_stale_ids(state, []), do: {:ok, state}

  defp delete_stale_ids(state, source_ids) do
    case mutate_current(state, fn conn, revision ->
           each_ok(source_ids, &delete_source(conn, &1, revision))
         end) do
      {:ok, _result, next} -> {:ok, next}
      {:error, reason, _next} -> {:error, reason}
    end
  end

  defp bounded_fts_merge(conn) do
    SQLite.write(conn, "INSERT INTO search_fts(search_fts, rank) VALUES('merge', 4)")
  end

  defp prune_obsolete_files(root, limit) do
    root
    |> obsolete_file_paths()
    |> Enum.take(limit)
    |> Enum.count(fn path -> File.rm(path) == :ok end)
  end

  defp obsolete_file_paths(root) do
    ["failed-*.sqlite3*", "retired-*.sqlite3*", "pending-prune-*.sqlite3*"]
    |> Enum.flat_map(&(root |> Path.join(&1) |> Path.wildcard()))
    |> Enum.sort()
  end

  defp build_generation(state, snapshots, primary) do
    generation_id = uuid7()
    builder_path = Path.join(state.root, "build-#{generation_id}.sqlite3")

    rebuilding = %{
      "domain" => "search",
      "state" => "rebuilding",
      "current_generation_id" => state.control["current_generation_id"],
      "previous_generation_id" => state.control["previous_generation_id"],
      "builder_generation_id" => generation_id,
      "builder" => nil,
      "projection_revision" => state.control["projection_revision"] || 0,
      "source_cursors" => state.control["source_cursors"] || %{},
      "dirty" => true,
      "last_error_code" => nil
    }

    with :ok <- write_control(state.root, rebuilding),
         {:ok, builder_conn} <- Sqlite3.open(builder_path),
         :ok <-
           Schema.create(builder_conn, %{
             generation_id: generation_id,
             eligibility_epoch: primary.eligibility_epoch,
             high_water: primary.high_water
           }) do
      populate_and_promote(state, snapshots, generation_id, builder_conn, rebuilding)
    else
      {:error, reason} -> fail_rebuild(state, reason, nil)
    end
  end

  defp populate_and_promote(state, snapshots, generation_id, builder_conn, rebuilding) do
    with {:ok, build} <- populate_snapshots(builder_conn, snapshots),
         :ok <- current_epochs(snapshots),
         {:ok, source_advanced?} <- source_advanced?(snapshots),
         {:ok, _capability} <- Schema.verify(builder_conn, generation_id),
         {:ok, promoted} <- promote(state, generation_id, builder_conn) do
      build =
        build
        |> Map.put(:source_advanced?, source_advanced?)
        |> Map.put(:source_cursors, snapshot_high_waters(snapshots))

      finish_rebuild(state, generation_id, rebuilding, build, promoted)
    else
      {:error, reason, promoted} ->
        fail_rebuild(state, reason, promoted)

      {:error, reason} ->
        _ = Sqlite3.close(builder_conn)
        fail_rebuild(state, reason, nil)
    end
  end

  defp populate_snapshots(conn, snapshots) do
    Enum.reduce_while(
      snapshots,
      {:ok, %{count: 0, revision: 0, indexed_through: nil}},
      fn snapshot, {:ok, acc} ->
        case populate_snapshot(conn, snapshot, nil, acc) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    )
  end

  defp populate_snapshot(conn, snapshot, cursor, acc) do
    with {:ok, page} <- Corpus.page(snapshot, cursor, @page_size),
         {:ok, next} <- write_page(conn, page.items, page.cursor, acc) do
      if page.exhausted?,
        do: {:ok, next},
        else: populate_snapshot(conn, snapshot, page.cursor, next)
    end
  end

  defp write_page(_conn, [], _cursor, acc), do: {:ok, acc}

  defp write_page(conn, envelopes, cursor, acc) do
    revision = acc.revision + 1

    case SQLite.transaction(conn, fn ->
           write_page_transaction(conn, envelopes, cursor, revision)
         end) do
      {:ok, :written} ->
        {:ok,
         %{
           count: acc.count + length(envelopes),
           revision: revision,
           indexed_through: cursor
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_page_transaction(conn, envelopes, cursor, revision) do
    with :ok <- each_ok(envelopes, &upsert_envelope(conn, &1, revision)),
         :ok <- update_generation_progress(conn, revision, cursor) do
      {:ok, :written}
    end
  end

  defp finish_rebuild(state, generation_id, rebuilding, build, promoted) do
    control = %{
      rebuilding
      | "state" => "ready",
        "current_generation_id" => generation_id,
        "previous_generation_id" => state.control["current_generation_id"],
        "builder_generation_id" => nil,
        "builder" => nil,
        "projection_revision" => build.revision,
        "source_cursors" => build.source_cursors,
        "dirty" => build.source_advanced?,
        "last_error_code" => nil
    }

    with :ok <- write_control(state.root, control) do
      _ = Managed.kick("search-index", "local")

      next = %{
        state
        | serving_conn: promoted.serving_conn,
          control: control,
          ready?: true,
          diagnostics: []
      }

      {:ok,
       %{
         generation_id: generation_id,
         projection_revision: build.revision,
         document_count: build.count,
         indexed_through: encode_corpus_cursor(build.indexed_through)
       }, next}
    else
      {:error, reason} ->
        _ = Sqlite3.close(promoted.serving_conn)
        fail_rebuild(state, {:control_write_failed, reason}, %{promoted | serving_conn: nil})
    end
  end

  defp promote(state, generation_id, builder_conn) do
    PromoteProtocol.promote(
      root: state.root,
      generation_id: generation_id,
      builder_conn: builder_conn,
      serving_conn: state.serving_conn,
      verify: fn conn, _path -> verify_for_promote(conn, generation_id) end,
      quiesce: fn -> :ok end
    )
  end

  defp verify_for_promote(conn, generation_id) do
    case Schema.verify(conn, generation_id) do
      {:ok, _capability} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fail_rebuild(state, reason, promoted) do
    serving_conn = if is_map(promoted), do: promoted.serving_conn, else: state.serving_conn

    control =
      state.control
      |> Map.put("state", if(serving_conn, do: "degraded", else: "not_ready"))
      |> Map.put("builder_generation_id", nil)
      |> Map.put("builder", nil)
      |> Map.put("dirty", true)
      |> Map.put("last_error_code", error_code(reason))

    _ = write_control(state.root, control)

    {:error, reason,
     %{
       state
       | serving_conn: serving_conn,
         control: control,
         ready?: not is_nil(serving_conn),
         diagnostics: [%{code: error_code(reason)}]
     }}
  end

  defp snapshots(operator_id) do
    policies()
    |> Enum.reduce_while({:ok, []}, fn policy, {:ok, acc} ->
      case Corpus.snapshot(operator_id, policy) do
        {:ok, snapshot} -> {:cont, {:ok, [snapshot | acc]}}
        {:error, :origin_grant_required} -> {:cont, {:ok, acc}}
        {:error, :e2ee_grant_required} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :search_disabled}
      {:ok, snapshots} -> {:ok, Enum.reverse(snapshots)}
      error -> error
    end
  end

  defp policies do
    grants = setting("search.origin_grants", ["local_operator"])

    [
      if("local_operator" in grants,
        do: %{consumer: :search, origin_scope: :local_operator, e2ee?: false}
      ),
      if("mapped_operator_dm" in grants and "e2ee_operator" in grants,
        do: %{consumer: :search, origin_scope: :mapped_operator_dm, e2ee?: true}
      ),
      if("mapped_operator_dm" in grants and "e2ee_operator" not in grants,
        do: %{consumer: :search, origin_scope: :mapped_operator_dm, e2ee?: false}
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp primary_snapshot([snapshot | _rest]), do: {:ok, snapshot}
  defp primary_snapshot([]), do: {:error, :search_disabled}

  defp current_epochs(snapshots) do
    if Enum.all?(snapshots, &(Corpus.eligibility_epoch(:search) == &1.eligibility_epoch)),
      do: :ok,
      else: {:error, :eligibility_changed}
  end

  defp source_advanced?(snapshots) do
    Enum.reduce_while(snapshots, {:ok, false}, fn snapshot, {:ok, advanced?} ->
      case Corpus.snapshot(snapshot.operator_id, snapshot.policy) do
        {:ok, current} ->
          {:cont, {:ok, advanced? or current.high_water != snapshot.high_water}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp mutate_current(state, mutation) do
    with {:ok, meta} <- generation_meta(state.serving_conn),
         revision = meta.projection_revision + 1,
         {:ok, result} <-
           SQLite.transaction(state.serving_conn, fn ->
             mutate_current_transaction(state.serving_conn, mutation, revision)
           end) do
      control =
        state.control |> Map.put("projection_revision", revision) |> Map.put("dirty", false)

      :ok = write_control(state.root, control)
      {:ok, result, %{state | control: control}}
    else
      {:error, reason} -> {:error, reason, mark_dirty(state, reason)}
    end
  end

  defp mutate_current_transaction(conn, mutation, revision) do
    with :ok <- mutation.(conn, revision),
         :ok <- set_revision(conn, revision) do
      {:ok, %{projection_revision: revision}}
    end
  end

  defp upsert_envelope(conn, %SourceEnvelope{} = envelope, revision) do
    with {:ok, rowid} <- existing_rowid(conn, envelope.source_id),
         {:ok, rowid} <- ensure_locator(conn, rowid, envelope, revision),
         :ok <- replace_fts(conn, rowid, Redactor.redact(envelope.content)) do
      :ok
    end
  end

  defp existing_rowid(conn, source_id) do
    case SQLite.query_one(
           conn,
           "SELECT fts_rowid FROM documents WHERE source_type = 'conversation' AND source_id = ?",
           [source_id]
         ) do
      {:ok, [rowid]} -> {:ok, rowid}
      {:error, :not_found} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_locator(conn, nil, envelope, revision) do
    values = locator_values(envelope, revision)

    with :ok <- SQLite.write(conn, locator_insert_sql(), values),
         {:ok, rowid} <- Sqlite3.last_insert_rowid(conn) do
      {:ok, rowid}
    end
  end

  defp ensure_locator(conn, rowid, envelope, _revision) do
    with :ok <- SQLite.write(conn, locator_update_sql(), locator_update_values(envelope, rowid)) do
      {:ok, rowid}
    end
  end

  defp replace_fts(conn, rowid, content) when is_binary(content) do
    with :ok <- SQLite.write(conn, "DELETE FROM search_fts WHERE rowid = ?", [rowid]),
         :ok <-
           SQLite.write(conn, "INSERT INTO search_fts(rowid, searchable_text) VALUES(?, ?)", [
             rowid,
             content
           ]) do
      :ok
    end
  end

  defp delete_source(conn, source_id, _revision) do
    case existing_rowid(conn, source_id) do
      {:ok, nil} ->
        :ok

      {:ok, rowid} ->
        with :ok <- SQLite.write(conn, "DELETE FROM search_fts WHERE rowid = ?", [rowid]),
             :ok <- SQLite.write(conn, "DELETE FROM documents WHERE fts_rowid = ?", [rowid]) do
          :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp query_candidates(state, query, position) do
    with {:ok, meta} <- generation_meta(state.serving_conn),
         {sql, params} <- candidate_sql(query, position),
         {:ok, rows} <- SQLite.query(state.serving_conn, sql, params) do
      {:ok,
       %{
         candidates: Enum.map(rows, &candidate_from_row/1),
         generation_id: meta.generation_id,
         projection_revision: meta.projection_revision,
         indexed_through: meta.indexed_through,
         last_indexed_at_us: meta.last_indexed_at_us
       }}
    end
  end

  defp candidate_sql(query, position) do
    {filter_sql, filter_values} = filter_sql(query.filters)
    {cursor_sql, cursor_values} = cursor_sql(query.order, position)
    order_sql = order_sql(query.order)

    sql =
      "WITH ranked AS (SELECT d.source_id, d.content_digest, d.timestamp_us, " <>
        "d.thread_id, d.origin_scope, d.e2ee, d.owner_scope, d.channel, " <>
        "d.receiver_account_ref, d.provider_thread_key, bm25(search_fts) AS score " <>
        "FROM search_fts JOIN documents d " <>
        "ON d.fts_rowid = search_fts.rowid WHERE search_fts MATCH ?#{filter_sql}) " <>
        "SELECT source_id, content_digest, timestamp_us, thread_id, origin_scope, e2ee, " <>
        "owner_scope, channel, receiver_account_ref, provider_thread_key, score FROM ranked " <>
        "WHERE 1 = 1#{cursor_sql} ORDER BY #{order_sql} LIMIT ?"

    {sql, [query.match] ++ filter_values ++ cursor_values ++ [@candidate_batch]}
  end

  defp filter_sql(filters) do
    Enum.reduce(filters, {"", []}, fn
      {:authors, values}, {sql, params} ->
        in_filter(sql, params, "d.author", values)

      {:surfaces, values}, {sql, params} ->
        in_filter(sql, params, "d.surface", values)

      {:thread_ids, values}, {sql, params} ->
        in_filter(sql, params, "d.thread_id", values)

      {:after, value}, {sql, params} ->
        {sql <> " AND d.timestamp_us > ?", params ++ [timestamp_us(value)]}

      {:before, value}, {sql, params} ->
        {sql <> " AND d.timestamp_us < ?", params ++ [timestamp_us(value)]}

      {:origin_scope, value}, {sql, params} ->
        {sql <> " AND d.origin_scope = ?", params ++ [to_string(value)]}

      {:e2ee, value}, {sql, params} ->
        {sql <> " AND d.e2ee = ?", params ++ [if(value, do: 1, else: 0)]}
    end)
  end

  defp in_filter(sql, params, column, values) do
    placeholders = Enum.map_join(values, ", ", fn _ -> "?" end)
    {sql <> " AND #{column} IN (#{placeholders})", params ++ Enum.map(values, &to_string/1)}
  end

  defp cursor_sql(_order, nil), do: {"", []}

  defp cursor_sql(:relevance, %{score: score, timestamp_us: timestamp, source_id: source_id}) do
    {" AND (score > ? OR (score = ? AND (timestamp_us < ? OR " <>
       "(timestamp_us = ? AND source_id > ?))))", [score, score, timestamp, timestamp, source_id]}
  end

  defp cursor_sql(:newest, %{timestamp_us: timestamp, source_id: source_id}) do
    {" AND (timestamp_us < ? OR (timestamp_us = ? AND source_id > ?))",
     [timestamp, timestamp, source_id]}
  end

  defp cursor_sql(:oldest, %{timestamp_us: timestamp, source_id: source_id}) do
    {" AND (timestamp_us > ? OR (timestamp_us = ? AND source_id > ?))",
     [timestamp, timestamp, source_id]}
  end

  defp order_sql(:relevance), do: "score ASC, timestamp_us DESC, source_id ASC"
  defp order_sql(:newest), do: "timestamp_us DESC, source_id ASC"
  defp order_sql(:oldest), do: "timestamp_us ASC, source_id ASC"

  defp candidate_from_row([
         source_id,
         digest,
         timestamp_us,
         thread_id,
         origin_scope,
         e2ee,
         owner_scope,
         channel,
         receiver_account_ref,
         provider_thread_key,
         score
       ]) do
    %{
      source_id: source_id,
      content_digest: digest,
      timestamp_us: timestamp_us,
      thread_id: thread_id,
      origin_scope: String.to_existing_atom(origin_scope),
      e2ee?: e2ee == 1,
      origin: %{
        owner_scope: owner_scope,
        channel: channel,
        receiver_account_ref: receiver_account_ref,
        provider_thread_key: provider_thread_key
      },
      score: score,
      position: %{score: score, timestamp_us: timestamp_us, source_id: source_id}
    }
  end

  defp generation_meta(conn) do
    case SQLite.query_one(
           conn,
           "SELECT generation_id, projection_revision, indexed_through_at_us, " <>
             "indexed_through_id, last_indexed_at_us FROM generation_meta WHERE id = 1"
         ) do
      {:ok, [generation_id, revision, at_us, source_id, last_indexed]} ->
        {:ok,
         %{
           generation_id: generation_id,
           projection_revision: revision,
           indexed_through: encode_watermark(at_us, source_id),
           last_indexed_at_us: last_indexed
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp status_map(state) do
    meta = if state.ready?, do: generation_meta(state.serving_conn), else: {:error, :not_ready}

    %{
      ready?: state.ready?,
      state: state.control["state"],
      dirty?: state.control["dirty"],
      purge_phase:
        case state.purge_control do
          %{"phase" => phase} -> phase
          :invalid -> "invalid"
          _other -> nil
        end,
      generation:
        case meta do
          {:ok, value} -> value
          {:error, _reason} -> nil
        end,
      diagnostics: state.diagnostics
    }
  end

  defp load_generation(root) do
    control = read_control(root)
    current_path = Path.join(root, "current.sqlite3")

    case open_verified(current_path) do
      {:ok, conn, generation_id, revision} ->
        control =
          control
          |> Map.put("state", "ready")
          |> Map.put("current_generation_id", generation_id)
          |> Map.put("projection_revision", revision)

        _ = write_control(root, control)
        {conn, control, []}

      {:error, :enoent} ->
        {nil, control, []}

      {:error, reason} ->
        recover_previous(root, control, reason)
    end
  end

  defp recover_previous(root, control, current_error) do
    current = Path.join(root, "current.sqlite3")
    previous = Path.join(root, "previous.sqlite3")
    _ = remove_database(current)

    case File.rename(previous, current) do
      :ok ->
        case open_verified(current) do
          {:ok, conn, generation_id, revision} ->
            recovered =
              control
              |> Map.put("state", "degraded")
              |> Map.put("current_generation_id", generation_id)
              |> Map.put("previous_generation_id", nil)
              |> Map.put("projection_revision", revision)
              |> Map.put("last_error_code", "current_generation_recovered")

            _ = write_control(root, recovered)
            {conn, recovered, [%{code: "current_generation_recovered"}]}

          {:error, reason} ->
            not_ready(control, {:current_and_previous_invalid, current_error, reason})
        end

      {:error, :enoent} ->
        not_ready(control, current_error)

      {:error, reason} ->
        not_ready(control, {:previous_recovery_failed, reason})
    end
  end

  defp open_verified(path) do
    case Sqlite3.open(path, mode: :readwrite) do
      {:ok, conn} ->
        verify_open_connection(conn)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_open_connection(conn) do
    with {:ok, _capability} <- Schema.verify(conn),
         {:ok, meta} <- generation_meta(conn) do
      {:ok, conn, meta.generation_id, meta.projection_revision}
    else
      {:error, reason} -> close_error(conn, reason)
    end
  end

  defp close_error(conn, reason) do
    _ = Sqlite3.close(conn)
    {:error, reason}
  end

  defp not_ready(control, reason) do
    control =
      control
      |> Map.put("state", "not_ready")
      |> Map.put("dirty", true)
      |> Map.put("last_error_code", error_code(reason))

    {nil, control, [%{code: error_code(reason)}]}
  end

  defp mark_dirty(state, reason) do
    control =
      state.control
      |> Map.put("state", "degraded")
      |> Map.put("dirty", true)
      |> Map.put("last_error_code", error_code(reason))

    _ = write_control(state.root, control)
    %{state | control: control, diagnostics: [%{code: error_code(reason)} | state.diagnostics]}
  end

  defp default_control do
    %{
      "domain" => "search",
      "state" => "not_ready",
      "current_generation_id" => nil,
      "previous_generation_id" => nil,
      "builder_generation_id" => nil,
      "builder" => nil,
      "projection_revision" => 0,
      "source_cursors" => %{},
      "dirty" => true,
      "last_error_code" => nil
    }
  end

  defp read_control(root) do
    case File.read(Path.join(root, @control_file)) do
      {:ok, bytes} ->
        case Jason.decode(bytes) do
          {:ok, decoded} when is_map(decoded) -> Map.merge(default_control(), decoded)
          _error -> default_control()
        end

      {:error, _reason} ->
        default_control()
    end
  end

  defp write_control(root, control) do
    path = Path.join(root, @control_file)
    tmp = path <> ".tmp-" <> uuid7()
    bytes = Jason.encode_to_iodata!(control, pretty: true)

    with :ok <- File.mkdir_p(root),
         :ok <- File.write(tmp, bytes, [:binary, :exclusive]),
         {:ok, io} <- File.open(tmp, [:read, :binary]),
         :ok <- sync_and_close(io),
         :ok <- File.rename(tmp, path),
         :ok <- sync_directory(root) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  defp sync_and_close(io) do
    try do
      :file.sync(io)
    after
      File.close(io)
    end
  end

  defp sync_directory(directory) do
    case :file.open(String.to_charlist(directory), [:read, :directory]) do
      {:ok, io} -> sync_and_close(io)
      {:error, :eisdir} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_database(path) do
    Enum.each([path, path <> "-wal", path <> "-shm"], fn file ->
      case File.rm(file) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, _reason} -> :ok
      end
    end)
  end

  defp update_generation_progress(conn, revision, nil), do: set_revision(conn, revision)

  defp update_generation_progress(conn, revision, %Corpus.Cursor{} = cursor) do
    SQLite.write(
      conn,
      "UPDATE generation_meta SET projection_revision = ?, indexed_through_at_us = ?, " <>
        "indexed_through_id = ?, last_indexed_at_us = ? WHERE id = 1",
      [
        revision,
        timestamp_us(cursor.inserted_at),
        cursor.source_id,
        System.system_time(:microsecond)
      ]
    )
  end

  defp set_revision(conn, revision) do
    SQLite.write(
      conn,
      "UPDATE generation_meta SET projection_revision = ?, last_indexed_at_us = ? WHERE id = 1",
      [revision, System.system_time(:microsecond)]
    )
  end

  defp each_ok(values, fun) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case fun.(value) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp locator_insert_sql do
    "INSERT INTO documents(source_type, source_id, thread_id, author, trust, surface, " <>
      "thread_kind, origin_scope, e2ee, timestamp_us, source_version, content_digest, " <>
      "redactor_version, tokenizer_version, schema_version, first_projected_revision, " <>
      "owner_scope, channel, receiver_account_ref, provider_thread_key) " <>
      "VALUES('conversation', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
  end

  defp locator_update_sql do
    "UPDATE documents SET thread_id = ?, author = ?, trust = ?, surface = ?, thread_kind = ?, " <>
      "origin_scope = ?, e2ee = ?, timestamp_us = ?, source_version = ?, content_digest = ?, " <>
      "redactor_version = ?, tokenizer_version = ?, schema_version = ?, owner_scope = ?, " <>
      "channel = ?, receiver_account_ref = ?, provider_thread_key = ? WHERE fts_rowid = ?"
  end

  defp locator_values(envelope, revision) do
    origin = envelope.origin || %{}

    [
      envelope.source_id,
      envelope.thread_id,
      to_string(envelope.author),
      to_string(envelope.trust),
      envelope.surface,
      envelope.thread_kind,
      to_string(envelope.origin_scope),
      if(:e2ee_operator in envelope.origin_overlays, do: 1, else: 0),
      timestamp_us(envelope.inserted_at),
      envelope.source_version,
      envelope.content_digest,
      Schema.redactor_version(),
      Schema.tokenizer_version(),
      Schema.schema_version(),
      revision,
      origin[:owner_scope],
      origin[:channel],
      origin[:receiver_account_ref],
      origin[:provider_thread_key]
    ]
  end

  defp locator_update_values(envelope, rowid) do
    [_source_id | values] = locator_values(envelope, 0)
    {_first_revision, values} = List.pop_at(values, 13)
    values ++ [rowid]
  end

  defp timestamp_us(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)

  defp encode_corpus_cursor(nil), do: nil

  defp encode_corpus_cursor(%Corpus.Cursor{} = cursor) do
    %{timestamp: cursor.inserted_at, source_id: cursor.source_id}
  end

  defp snapshot_high_waters(snapshots) do
    Map.new(snapshots, fn snapshot ->
      {policy_key(snapshot.policy), encode_source_watermark(snapshot.high_water)}
    end)
  end

  defp encode_builder_snapshot(snapshot) do
    %{
      "operator_id" => snapshot.operator_id,
      "policy" => %{
        "consumer" => Atom.to_string(snapshot.policy.consumer),
        "origin_scope" => Atom.to_string(snapshot.policy.origin_scope),
        "e2ee" => snapshot.policy.e2ee?
      },
      "high_water" => encode_source_watermark(snapshot.high_water),
      "eligibility_epoch" => snapshot.eligibility_epoch,
      "binding" => snapshot.binding
    }
  end

  defp decode_builder_snapshots(%{"snapshots" => snapshots}) when is_list(snapshots) do
    Enum.reduce_while(snapshots, {:ok, []}, fn encoded, {:ok, acc} ->
      case decode_builder_snapshot(encoded) do
        {:ok, snapshot} -> {:cont, {:ok, [snapshot | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp decode_builder_snapshots(_builder), do: {:error, :invalid_builder_state}

  defp decode_builder_snapshot(encoded) when is_map(encoded) do
    policy = encoded["policy"] || %{}

    with {:ok, origin_scope} <- decode_origin_scope(policy["origin_scope"]),
         {:ok, high_water} <- decode_high_water(encoded["high_water"]),
         true <- is_binary(encoded["operator_id"]),
         true <- is_integer(encoded["eligibility_epoch"]),
         true <- is_binary(encoded["binding"]),
         true <- policy["consumer"] == "search",
         true <- is_boolean(policy["e2ee"]) do
      {:ok,
       %Corpus.Snapshot{
         operator_id: encoded["operator_id"],
         policy: %{consumer: :search, origin_scope: origin_scope, e2ee?: policy["e2ee"]},
         high_water: high_water,
         eligibility_epoch: encoded["eligibility_epoch"],
         binding: encoded["binding"]
       }}
    else
      _invalid -> {:error, :invalid_builder_state}
    end
  end

  defp decode_builder_snapshot(_encoded), do: {:error, :invalid_builder_state}

  defp decode_origin_scope("local_operator"), do: {:ok, :local_operator}
  defp decode_origin_scope("mapped_operator_dm"), do: {:ok, :mapped_operator_dm}
  defp decode_origin_scope(_scope), do: {:error, :invalid_builder_state}

  defp decode_high_water(nil), do: {:ok, nil}

  defp decode_high_water(value) do
    case decode_source_watermark(value) do
      %{inserted_at: inserted_at, source_id: source_id} -> {:ok, {inserted_at, source_id}}
      _invalid -> {:error, :invalid_builder_state}
    end
  end

  defp policy_key(policy),
    do: "#{policy.origin_scope}:#{if(policy.e2ee?, do: "e2ee", else: "plain")}"

  defp cursor_watermark(nil), do: nil
  defp cursor_watermark(%Corpus.Cursor{} = cursor), do: {cursor.inserted_at, cursor.source_id}

  defp encode_source_watermark(nil), do: nil

  defp encode_source_watermark({%DateTime{} = inserted_at, source_id}) do
    %{"inserted_at" => DateTime.to_iso8601(inserted_at), "source_id" => source_id}
  end

  defp decode_source_watermark(nil), do: nil

  defp decode_source_watermark(%{"inserted_at" => inserted_at, "source_id" => source_id}) do
    case DateTime.from_iso8601(inserted_at) do
      {:ok, datetime, _offset} -> %{inserted_at: datetime, source_id: source_id}
      _error -> nil
    end
  end

  defp decode_source_watermark(_value), do: nil

  defp encode_watermark(nil, nil), do: nil

  defp encode_watermark(timestamp_us, source_id) do
    %{timestamp: DateTime.from_unix!(timestamp_us, :microsecond), source_id: source_id}
  end

  defp setting(key, default) do
    case Settings.get(key) do
      {:ok, value} -> value
      _other -> default
    end
  end

  defp error_code(reason) do
    case reason do
      atom when is_atom(atom) -> Atom.to_string(atom)
      {atom, _detail} when is_atom(atom) -> Atom.to_string(atom)
      {atom, _detail, _more} when is_atom(atom) -> Atom.to_string(atom)
      _other -> "search_projection_failed"
    end
  end

  defp uuid7 do
    timestamp_ms = System.system_time(:millisecond)
    <<rand_a::12, rand_b::62, _unused::6>> = :crypto.strong_rand_bytes(10)

    <<timestamp_ms::48, 7::4, rand_a::12, 2::2, rand_b::62>>
    |> Base.encode16(case: :lower)
    |> format_uuid()
  end

  defp format_uuid(
         <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
           e::binary-size(12)>>
       ),
       do: a <> "-" <> b <> "-" <> c <> "-" <> d <> "-" <> e
end
