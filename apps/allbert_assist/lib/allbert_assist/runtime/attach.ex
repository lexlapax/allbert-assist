defmodule AllbertAssist.Runtime.Attach do
  @moduledoc """
  Local attach transport for packaged `allbert` commands (v0.62 M8.1).

  The daemon listens on a Unix-domain socket under Allbert Home runtime state.
  A short token file, protocol version, Home, uid, and app version bind each
  request to the running daemon. The transport is intentionally local-only and
  release-distribution-free.
  """

  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime.Attach.TUIProtocol

  @protocol_version 1
  @runtime_dir "runtime"
  @socket_file "attach.sock"
  @token_file "attach.token"
  @connect_timeout 1_000
  @recv_timeout 30_000
  @tui_open_timeout 5_000

  @type response :: {:ok, {String.t(), non_neg_integer()}} | {:error, term()}

  @doc "The attach protocol version accepted by this release."
  @spec protocol_version() :: 1
  def protocol_version, do: @protocol_version

  @doc "Allbert Home-local runtime directory for attach state."
  @spec runtime_dir() :: String.t()
  def runtime_dir, do: Path.join(Paths.home(), @runtime_dir)

  @doc """
  Unix-domain socket path used by the daemon attach server.

  Operator-validation F3: UDS paths are bounded by `sun_path` (104 bytes on macOS/BSD,
  incl. the NUL terminator). A deep `ALLBERT_HOME` can push the Home-local socket past
  that, which previously failed `listen` with `:einval` and crashed the whole daemon. When
  the Home-local path would not fit, fall back to a short, per-Home-stable path in the OS
  temp dir (the server binds it and the client derives the same path deterministically).
  """
  @spec socket_path() :: String.t()
  def socket_path do
    natural = Path.join(runtime_dir(), @socket_file)
    if uds_path_ok?(natural), do: natural, else: short_socket_path()
  end

  # A byte of margin under the smallest common sun_path limit (104).
  @uds_path_max 100
  defp uds_path_ok?(path), do: byte_size(path) < @uds_path_max

  defp short_socket_path do
    digest =
      :crypto.hash(:sha256, Paths.home())
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 16)

    candidate = Path.join(System.tmp_dir!(), "allbert-#{digest}.sock")
    if uds_path_ok?(candidate), do: candidate, else: Path.join("/tmp", "allbert-#{digest}.sock")
  end

  @doc "Token path used to authenticate local attach clients."
  @spec token_path() :: String.t()
  def token_path, do: Path.join(runtime_dir(), @token_file)

  @doc "Remove a stale socket file before a daemon starts listening."
  @spec remove_stale_socket() :: :ok
  def remove_stale_socket do
    _ = File.rm(socket_path())
    :ok
  end

  @doc "Read or create the per-Home attach token."
  @spec ensure_token!() :: String.t()
  def ensure_token! do
    File.mkdir_p!(runtime_dir())
    chmod_owner_traversable(runtime_dir())

    case File.read(token_path()) do
      {:ok, token} ->
        String.trim(token)

      {:error, _reason} ->
        token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
        # v0.62 M8.9: create the (empty) file and narrow it to 0600 BEFORE the
        # secret is written, so the token never exists in a world/group-readable
        # file (the parent runtime dir is already 0700).
        File.touch!(token_path())
        chmod_owner_only(token_path())
        File.write!(token_path(), token <> "\n")
        token
    end
  end

  @doc "Read the attach token if both socket and token exist."
  @spec read_token() :: {:ok, String.t()} | {:error, :not_available | File.posix()}
  def read_token do
    if File.exists?(socket_path()) do
      case File.read(token_path()) do
        {:ok, token} -> {:ok, String.trim(token)}
        {:error, :enoent} -> {:error, :not_available}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_available}
    end
  end

  @doc "Return request identity fields shared by client and server."
  @spec identity() :: %{protocol: 1, home: String.t(), uid: String.t() | nil, version: String.t()}
  def identity do
    %{
      protocol: @protocol_version,
      home: Path.expand(Paths.home()),
      uid: uid(),
      version: app_version()
    }
  end

  @doc "Build an authenticated request packet for argv."
  @spec request([String.t()], String.t()) :: map()
  def request(argv, token) do
    identity()
    |> Map.merge(%{token: token, argv: argv})
  end

  @doc "Validate an attach request against the daemon's identity."
  @spec validate_request(map(), String.t()) :: :ok | {:error, atom()}
  def validate_request(%{} = request, token) do
    identity = identity()

    cond do
      Map.get(request, :protocol) != @protocol_version ->
        {:error, :protocol_mismatch}

      # v0.62 M8.16: constant-time compare so a client cannot time-probe the
      # attach token byte-by-byte.
      not tokens_match?(Map.get(request, :token), token) ->
        {:error, :token_mismatch}

      not home_matches?(Map.get(request, :home), identity.home) ->
        {:error, :home_mismatch}

      not string_matches?(Map.get(request, :uid, ""), identity.uid) ->
        {:error, :uid_mismatch}

      not string_matches?(Map.get(request, :version, ""), identity.version) ->
        {:error, :version_mismatch}

      not argv?(Map.get(request, :argv)) ->
        {:error, :invalid_argv}

      true ->
        :ok
    end
  end

  def validate_request(_request, _token), do: {:error, :invalid_request}

  defp tokens_match?(candidate, token) when is_binary(candidate) and is_binary(token) do
    Plug.Crypto.secure_compare(candidate, token)
  end

  defp tokens_match?(_candidate, _token), do: false

  defp home_matches?(candidate, expected) do
    with {:ok, home} <- safe_to_string(candidate) do
      Path.expand(home) == expected
    else
      :error -> false
    end
  rescue
    _error -> false
  end

  defp string_matches?(candidate, expected) do
    case safe_to_string(candidate) do
      {:ok, value} -> value == expected
      :error -> false
    end
  end

  defp safe_to_string(value) do
    {:ok, to_string(value)}
  rescue
    _error -> :error
  end

  @doc "Client-side attach request."
  @spec run([String.t()]) :: response()
  def run(argv) do
    with {:ok, token} <- read_token(),
         {:ok, socket} <- connect(),
         :ok <- send_request(socket, request(argv, token)),
         response <- recv_response(socket) do
      :gen_tcp.close(socket)
      response
    else
      {:error, :enoent} -> {:error, :not_available}
      {:error, :econnrefused} -> {:error, :not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Low-level client request used by mismatch tests."
  @spec run_request(map()) :: response()
  def run_request(request) when is_map(request) do
    with {:ok, socket} <- connect(),
         :ok <- send_request(socket, request),
         response <- recv_response(socket) do
      :gen_tcp.close(socket)
      response
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Open one authenticated, passive daemon-backed TUI session."
  @spec open_tui_session(term(), term()) ::
          {:ok, :gen_tcp.socket(), map(), map()} | {:error, term()}
  def open_tui_session(profile, terminal) do
    with {:ok, token} <- read_token(),
         identity = Map.put(identity(), :token, token),
         {:ok, open} <- TUIProtocol.session_open(identity, profile, terminal),
         {:ok, socket} <- connect_tui_session() do
      finish_tui_open(socket, open)
    else
      {:error, reason} -> {:error, normalize_tui_open_error(reason)}
    end
  end

  defp connect do
    :gen_tcp.connect(
      {:local, socket_path()},
      0,
      [:binary, packet: 4, active: false],
      @connect_timeout
    )
  end

  defp connect_tui_session do
    :gen_tcp.connect(
      {:local, socket_path()},
      0,
      [
        :binary,
        packet: 4,
        packet_size: TUIProtocol.limits().frame_body_bytes,
        active: false
      ],
      @connect_timeout
    )
  end

  defp finish_tui_open(socket, open) do
    result =
      with {:ok, payload} <- encode_tui_open(open),
           :ok <- :gen_tcp.send(socket, payload),
           {:ok, response} <- :gen_tcp.recv(socket, 0, @tui_open_timeout),
           {:ok, initial_frame, accepted_flow} <-
             TUIProtocol.decode_initial_response(response) do
        {:ok, socket, initial_frame, accepted_flow}
      end

    case result do
      {:ok, ^socket, _initial_frame, _accepted_flow} = accepted ->
        accepted

      {:error, reason} ->
        :gen_tcp.close(socket)
        {:error, normalize_tui_open_error(reason)}
    end
  rescue
    _error ->
      :gen_tcp.close(socket)
      {:error, :protocol_error}
  end

  defp encode_tui_open(open) do
    payload = :erlang.term_to_binary(open)

    if byte_size(payload) <= TUIProtocol.limits().open_body_bytes and
         not TUIProtocol.compressed_term?(payload) do
      {:ok, payload}
    else
      {:error, :invalid_open}
    end
  rescue
    _error -> {:error, :invalid_open}
  end

  defp normalize_tui_open_error(reason) when reason in [:enoent, :econnrefused],
    do: :not_available

  defp normalize_tui_open_error(:emsgsize), do: :frame_too_large
  defp normalize_tui_open_error(reason), do: reason

  defp send_request(socket, request) do
    :gen_tcp.send(socket, :erlang.term_to_binary(request))
  end

  defp recv_response(socket) do
    case :gen_tcp.recv(socket, 0, @recv_timeout) do
      {:ok, payload} ->
        case safe_binary_to_term(payload) do
          {:ok, {:ok, {output, code}}} when is_binary(output) and is_integer(code) ->
            {:ok, {output, code}}

          {:ok, {:error, reason}} ->
            {:error, reason}

          _other ->
            {:error, :invalid_response}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_binary_to_term(payload) do
    {:ok, :erlang.binary_to_term(payload, [:safe])}
  rescue
    _error -> {:error, :invalid_term}
  end

  defp argv?(argv), do: is_list(argv) and Enum.all?(argv, &is_binary/1)

  defp app_version do
    :allbert_assist
    |> Application.spec(:vsn)
    |> to_string()
  end

  defp uid do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {uid, 0} -> String.trim(uid)
      _other -> System.get_env("UID") || "unknown"
    end
  rescue
    _error -> System.get_env("UID") || "unknown"
  end

  defp chmod_owner_only(path) do
    _ = File.chmod(path, 0o600)
    :ok
  end

  defp chmod_owner_traversable(path) do
    _ = File.chmod(path, 0o700)
    :ok
  end
end

defmodule AllbertAssist.Runtime.Attach.Server do
  @moduledoc """
  Daemon-side attach listener for unary commands and authenticated TUI sessions.

  The listener owns only socket admission, bounded pre-authentication workers,
  and the single provisional/active TUI reservation. Long-lived terminal state
  belongs to `AllbertAssist.Runtime.Attach.TUISession`.
  """

  use GenServer

  require Logger

  alias AllbertAssist.Runtime.Attach
  alias AllbertAssist.Runtime.Attach.TUIProtocol
  alias AllbertAssist.Runtime.Attach.TUISession
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.CLI

  @accept_timeout 1_000
  @recv_timeout 5_000
  # v0.62 M8.16: cap concurrent attached commands so a burst of clients can't
  # spawn unbounded tasks; extra clients get a fast `:busy` instead of blocking.
  @max_children 16
  @max_pending_handshakes 16
  # Attach requests are a small argv + identity map. Cap the pre-auth `packet: 4`
  # frame so an unauthenticated peer can't force a multi-gigabyte allocation.
  @max_frame_bytes 1_048_576

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return bounded attach-listener health without exposing socket or token material."
  @spec status(GenServer.server()) :: %{
          optional(:pending_handshakes) => non_neg_integer(),
          optional(:reason) => atom(),
          optional(:tui_session) => :none | :starting | :active,
          required(:status) => :up | :degraded
        }
  def status(server \\ __MODULE__), do: GenServer.call(server, :status, 1_000)

  @impl true
  def init(opts) do
    Attach.remove_stale_socket()
    token = Attach.ensure_token!()
    {:ok, task_sup} = Task.Supervisor.start_link(max_children: @max_children)

    state = %{
      listen_socket: nil,
      acceptor: nil,
      token: token,
      task_sup: task_sup,
      pending: %{},
      pending_limit: Keyword.get(opts, :pending_handshake_limit, @max_pending_handshakes),
      session: nil,
      session_module: Keyword.get(opts, :session_module, TUISession),
      session_opts: Keyword.get(opts, :session_opts, []),
      effect_guard_opts: effect_guard_opts(opts),
      status: :up,
      status_reason: nil
    }

    case :gen_tcp.listen(0, [
           :binary,
           packet: 4,
           packet_size: @max_frame_bytes,
           active: false,
           ifaddr: {:local, Attach.socket_path()}
         ]) do
      {:ok, listen_socket} ->
        owner = self()
        acceptor = spawn_link(fn -> accept_loop(owner, listen_socket) end)
        Logger.info("attach listener started at #{Attach.socket_path()}")

        {:ok, %{state | listen_socket: listen_socket, acceptor: acceptor}}

      {:error, reason} ->
        Logger.warning(
          "attach listener could not bind #{Attach.socket_path()} (#{inspect(reason)}); " <>
            "daemon attachment is unavailable — serve and Web continue degraded"
        )

        {:ok, %{state | status: :degraded, status_reason: reason}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      status: state.status,
      pending_handshakes: map_size(state.pending),
      tui_session: session_status(state.session)
    }

    status =
      if state.status_reason, do: Map.put(status, :reason, state.status_reason), else: status

    {:reply, status, state}
  end

  def handle_call(:reserve_handshake, _from, state) do
    if map_size(state.pending) < state.pending_limit do
      owner = self()
      {worker, monitor_ref} = spawn_monitor(fn -> handshake_worker(owner) end)
      pending = Map.put(state.pending, worker, %{monitor_ref: monitor_ref, session_pid: nil})
      {:reply, {:ok, worker}, %{state | pending: pending}}
    else
      {:reply, {:error, :capacity}, state}
    end
  end

  @impl true
  def handle_info({:attach_request, worker, request, wire}, state) do
    if Map.has_key?(state.pending, worker) do
      {instruction, state} = route_request(request, worker, wire, state)
      maybe_instruct(worker, instruction)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:attach_invalid, worker, reason}, state) do
    if Map.has_key?(state.pending, worker) do
      send(worker, {:reply_and_close, {:error, reason}})
    end

    {:noreply, state}
  end

  def handle_info({:attach_handoff, worker, result}, state) do
    state = finish_handoff(worker, result, state)
    {:noreply, state}
  end

  def handle_info({:tui_session_ready, session_pid}, state) do
    case state.session do
      %{pid: ^session_pid, worker: worker} = session ->
        send(worker, {:handoff, session_pid})
        {:noreply, %{state | session: %{session | ready?: true}}}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:tui_session_rejected, session_pid, code, message}, state) do
    case state.session do
      %{pid: ^session_pid, worker: worker, monitor_ref: monitor_ref} ->
        send(worker, {:reply_and_close, TUIProtocol.open_close(code, message)})
        Process.demonitor(monitor_ref, [:flush])
        {:noreply, %{state | session: nil}}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:attach_accept_error, reason}, state) do
    {:stop, {:attach_accept_failed, reason}, state}
  end

  def handle_info({:DOWN, monitor_ref, :process, pid, reason}, state) do
    cond do
      match?(%{pid: ^pid, monitor_ref: ^monitor_ref}, state.session) ->
        {:noreply, session_down(reason, state)}

      pending_monitor?(state, pid, monitor_ref) ->
        {:noreply, pending_down(pid, state)}

      true ->
        {:noreply, state}
    end
  end

  defp route_request(%{} = request, worker, wire, state) do
    case TUIProtocol.classify_kind(request) do
      {:ok, :command} ->
        route_command(request, state)

      {:ok, :tui_session} ->
        route_tui_open(request, worker, wire, state)

      {:error, :unsupported_kind} ->
        {{:reply_and_close,
          TUIProtocol.open_close(:unsupported_kind, "Unsupported request kind.")}, state}
    end
  end

  defp route_request(_request, _worker, _wire, state),
    do: {{:reply_and_close, {:error, :invalid_request}}, state}

  defp route_command(request, state) do
    case Attach.validate_request(request, state.token) do
      :ok ->
        case CLI.entry_plan(request.argv).disposition do
          :runtime_required -> route_runtime_command(request.argv, state)
          _runtime_free -> route_runtime_free_command(request.argv, state)
        end

      {:error, reason} ->
        {{:reply_and_close, {:error, reason}}, state}
    end
  end

  defp route_tui_open(request, worker, wire, state) do
    cond do
      wire.compressed? ->
        reject_open(:invalid_open, "Invalid TUI session open.", state)

      wire.body_bytes > TUIProtocol.limits().open_body_bytes ->
        reject_open(:invalid_open, "Invalid TUI session open.", state)

      not is_nil(state.session) ->
        reject_open(:already_attached, "A TUI session is already attached.", state)

      true ->
        expected = Map.put(Attach.identity(), :token, state.token)

        case TUIProtocol.validate_open(request, expected) do
          {:ok, open} ->
            with {:ok, epoch} <- EffectGuard.admit_ready(state.effect_guard_opts),
                 :ok <- EffectGuard.validate(epoch) do
              start_tui_session(open, worker, state, epoch)
            else
              {:error, _reason} ->
                reject_open(:runtime_unavailable, "Allbert product is not ready.", state)
            end

          {:error, reason} ->
            reject_open(reason, "TUI session open rejected.", state)
        end
    end
  end

  # The daemon's static attach routes deliberately remain runtime-free. Every
  # runtime-bearing command captures E1 here and carries it directly to the
  # residual CLI boundary; neither this listener nor the CLI may substitute a
  # replacement epoch mid-request.
  defp route_runtime_command(argv, state) do
    with {:ok, epoch} <- EffectGuard.admit_ready(state.effect_guard_opts) do
      case start_command_task(state.task_sup, argv, epoch) do
        {:ok, task_pid} -> {{:handoff, task_pid}, state}
        {:error, _reason} -> {{:reply_and_close, {:error, :busy}}, state}
      end
    else
      {:error, _reason} -> {{:reply_and_close, {:error, :product_not_ready}}, state}
    end
  end

  defp route_runtime_free_command(argv, state) do
    case start_command_task(state.task_sup, argv, nil) do
      {:ok, task_pid} -> {{:handoff, task_pid}, state}
      {:error, _reason} -> {{:reply_and_close, {:error, :busy}}, state}
    end
  end

  defp reject_open(code, message, state) do
    {{:reply_and_close, TUIProtocol.open_close(code, message)}, state}
  end

  defp start_tui_session(open, worker, state, epoch) do
    opts =
      [attach_server: self(), open: open, allbert_pack_epoch: epoch]
      |> Keyword.merge(state.session_opts)

    case state.session_module.start(opts) do
      {:ok, session_pid} ->
        monitor_ref = Process.monitor(session_pid)

        pending =
          Map.update!(state.pending, worker, fn handshake ->
            %{handshake | session_pid: session_pid}
          end)

        session = %{
          pid: session_pid,
          monitor_ref: monitor_ref,
          worker: worker,
          ready?: false,
          active?: false
        }

        {nil, %{state | pending: pending, session: session}}

      {:error, reason} ->
        Logger.warning("TUI session owner could not start: #{inspect(reason)}")
        reject_open(:runtime_unavailable, "TUI session could not start.", state)
    end
  end

  defp start_command_task(task_sup, argv, epoch) do
    Task.Supervisor.start_child(task_sup, fn ->
      receive do
        {:attach_socket, socket} ->
          send_response_and_close(socket, run_attached_isolated(argv, epoch))
      after
        @recv_timeout -> :ok
      end
    end)
  end

  # Run the attached command with a crash barrier so a failing command returns a
  # structured error instead of taking down the task/listener.
  defp run_attached_isolated(argv, nil) do
    {:ok, AllbertAssist.CLI.run_attached(argv)}
  rescue
    error -> {:error, {:command_crashed, Exception.message(error)}}
  catch
    kind, value -> {:error, {:command_crashed, inspect({kind, value})}}
  end

  defp run_attached_isolated(argv, epoch) do
    with :ok <- EffectGuard.validate(epoch) do
      {:ok, AllbertAssist.CLI.run_attached(argv, allbert_pack_epoch: epoch)}
    else
      {:error, _reason} -> {:error, :product_not_ready}
    end
  rescue
    error -> {:error, {:command_crashed, Exception.message(error)}}
  catch
    kind, value -> {:error, {:command_crashed, inspect({kind, value})}}
  end

  defp effect_guard_opts(opts) do
    case Keyword.fetch(opts, :readiness_server) do
      {:ok, server} -> [server: server]
      :error -> []
    end
  end

  defp send_response_and_close(socket, response) do
    _ = :gen_tcp.send(socket, :erlang.term_to_binary(response))
    :gen_tcp.close(socket)
  end

  defp maybe_instruct(_worker, nil), do: :ok
  defp maybe_instruct(worker, instruction), do: send(worker, instruction)

  defp finish_handoff(worker, :ok, state) do
    state = drop_pending(worker, state)

    case state.session do
      %{worker: ^worker} = session -> %{state | session: %{session | active?: true, worker: nil}}
      _other -> state
    end
  end

  defp finish_handoff(worker, {:error, reason}, state) do
    state = maybe_stop_worker_session(worker, {:socket_handoff_failed, reason}, state)
    drop_pending(worker, state)
  end

  defp pending_down(worker, state) do
    state = maybe_stop_worker_session(worker, :handshake_closed, state)
    drop_pending(worker, state, demonitor?: false)
  end

  defp pending_monitor?(state, pid, monitor_ref) do
    match?(%{monitor_ref: ^monitor_ref}, Map.get(state.pending, pid))
  end

  defp maybe_stop_worker_session(worker, reason, state) do
    case state.session do
      %{worker: ^worker, pid: session_pid, monitor_ref: monitor_ref} ->
        Process.demonitor(monitor_ref, [:flush])
        if Process.alive?(session_pid), do: GenServer.stop(session_pid, reason)
        %{state | session: nil}

      _other ->
        state
    end
  catch
    :exit, _reason -> %{state | session: nil}
  end

  defp session_down(reason, state) do
    case state.session do
      %{worker: worker} when is_pid(worker) ->
        send(
          worker,
          {:reply_and_close,
           TUIProtocol.open_close(
             :runtime_unavailable,
             "TUI session initialization failed."
           )}
        )

      _active_or_nil ->
        if reason not in [:normal, :shutdown],
          do: Logger.warning("TUI session owner stopped: #{inspect(reason)}")
    end

    %{state | session: nil}
  end

  defp drop_pending(worker, state, opts \\ []) do
    case Map.pop(state.pending, worker) do
      {nil, _pending} ->
        state

      {%{monitor_ref: monitor_ref}, pending} ->
        if Keyword.get(opts, :demonitor?, true), do: Process.demonitor(monitor_ref, [:flush])
        %{state | pending: pending}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.listen_socket, do: :gen_tcp.close(state.listen_socket)
    terminate_pending_workers(state.pending)

    if state.session && Process.alive?(state.session.pid),
      do: GenServer.stop(state.session.pid, :daemon_shutdown)

    Attach.remove_stale_socket()
    :ok
  end

  defp terminate_pending_workers(pending) do
    Enum.each(pending, fn {worker, _handshake} ->
      if Process.alive?(worker), do: Process.exit(worker, :shutdown)
    end)
  end

  defp accept_loop(owner, listen_socket) do
    case :gen_tcp.accept(listen_socket, @accept_timeout) do
      {:ok, socket} ->
        admit_socket(owner, socket)
        accept_loop(owner, listen_socket)

      {:error, :timeout} ->
        accept_loop(owner, listen_socket)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        send(owner, {:attach_accept_error, reason})
    end
  end

  defp admit_socket(owner, socket) do
    case GenServer.call(owner, :reserve_handshake, @recv_timeout) do
      {:ok, worker} ->
        case :gen_tcp.controlling_process(socket, worker) do
          :ok ->
            send(worker, {:accepted_socket, socket})

          {:error, reason} ->
            :gen_tcp.close(socket)
            send(owner, {:attach_handoff, worker, {:error, reason}})
        end

      {:error, :capacity} ->
        send_response_and_close(
          socket,
          TUIProtocol.open_close(:capacity, "Attach handshake capacity reached.")
        )
    end
  catch
    :exit, _reason -> :gen_tcp.close(socket)
  end

  defp handshake_worker(owner) do
    owner_monitor = Process.monitor(owner)

    receive do
      {:accepted_socket, socket} -> receive_open(owner, owner_monitor, socket)
      {:DOWN, ^owner_monitor, :process, ^owner, _reason} -> :ok
    after
      @recv_timeout -> :ok
    end
  end

  defp receive_open(owner, owner_monitor, socket) do
    case :inet.setopts(socket, active: :once) do
      :ok -> receive_open_frame(owner, owner_monitor, socket)
      {:error, reason} -> notify_invalid_and_await(owner, owner_monitor, socket, reason)
    end
  end

  defp receive_open_frame(owner, owner_monitor, socket) do
    receive do
      {:tcp, ^socket, payload} ->
        handle_open_payload(owner, owner_monitor, socket, payload)

      {:tcp_closed, ^socket} ->
        notify_invalid_and_await(owner, owner_monitor, socket, :closed)

      {:tcp_error, ^socket, reason} ->
        notify_invalid_and_await(owner, owner_monitor, socket, reason)

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        :gen_tcp.close(socket)
    after
      @recv_timeout -> notify_invalid_and_await(owner, owner_monitor, socket, :timeout)
    end
  end

  defp handle_open_payload(owner, owner_monitor, socket, payload) do
    case safe_binary_to_term(payload) do
      {:ok, request} ->
        wire = %{
          body_bytes: byte_size(payload),
          compressed?: TUIProtocol.compressed_term?(payload)
        }

        send(owner, {:attach_request, self(), request, wire})
        await_route(owner, owner_monitor, socket)

      {:error, reason} ->
        notify_invalid_and_await(owner, owner_monitor, socket, reason)
    end
  end

  defp notify_invalid_and_await(owner, owner_monitor, socket, reason) do
    send(owner, {:attach_invalid, self(), reason})
    await_route(owner, owner_monitor, socket)
  end

  defp await_route(owner, owner_monitor, socket) do
    receive do
      {:reply_and_close, response} ->
        send_response_and_close(socket, response)

      {:handoff, new_owner} when is_pid(new_owner) ->
        case :gen_tcp.controlling_process(socket, new_owner) do
          :ok ->
            send(new_owner, {:attach_socket, socket})
            send(owner, {:attach_handoff, self(), :ok})

          {:error, reason} ->
            :gen_tcp.close(socket)
            send(owner, {:attach_handoff, self(), {:error, reason}})
        end

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        :gen_tcp.close(socket)
    after
      @recv_timeout ->
        :gen_tcp.close(socket)
    end
  end

  defp safe_binary_to_term(payload) do
    {:ok, :erlang.binary_to_term(payload, [:safe])}
  rescue
    _error -> {:error, :invalid_term}
  end

  defp session_status(nil), do: :none
  defp session_status(%{active?: true}), do: :active
  defp session_status(%{}), do: :starting
end
