defmodule AllbertAssist.Runtime.Attach do
  @moduledoc """
  Local attach transport for packaged `allbert` commands (v0.62 M8.1).

  The daemon listens on a Unix-domain socket under Allbert Home runtime state.
  A short token file, protocol version, Home, uid, and app version bind each
  request to the running daemon. The transport is intentionally local-only and
  release-distribution-free.
  """

  alias AllbertAssist.Paths

  @protocol_version 1
  @runtime_dir "runtime"
  @socket_file "attach.sock"
  @token_file "attach.token"
  @connect_timeout 1_000
  @recv_timeout 30_000

  @type response :: {:ok, {String.t(), non_neg_integer()}} | {:error, term()}

  @doc "The attach protocol version accepted by this release."
  @spec protocol_version() :: 1
  def protocol_version, do: @protocol_version

  @doc "Allbert Home-local runtime directory for attach state."
  @spec runtime_dir() :: String.t()
  def runtime_dir, do: Path.join(Paths.home(), @runtime_dir)

  @doc "Unix-domain socket path used by the daemon attach server."
  @spec socket_path() :: String.t()
  def socket_path, do: Path.join(runtime_dir(), @socket_file)

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

      Map.get(request, :token) != token ->
        {:error, :token_mismatch}

      Path.expand(to_string(Map.get(request, :home, ""))) != identity.home ->
        {:error, :home_mismatch}

      to_string(Map.get(request, :uid, "")) != identity.uid ->
        {:error, :uid_mismatch}

      to_string(Map.get(request, :version, "")) != identity.version ->
        {:error, :version_mismatch}

      not argv?(Map.get(request, :argv)) ->
        {:error, :invalid_argv}

      true ->
        :ok
    end
  end

  def validate_request(_request, _token), do: {:error, :invalid_request}

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

  defp connect do
    :gen_tcp.connect(
      {:local, socket_path()},
      0,
      [:binary, packet: 4, active: false],
      @connect_timeout
    )
  end

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
  Daemon-side attach listener for `allbert` CLI commands.
  """

  use GenServer

  require Logger

  alias AllbertAssist.Runtime.Attach

  @accept_timeout 1_000
  @recv_timeout 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Attach.remove_stale_socket()
    token = Attach.ensure_token!()

    case :gen_tcp.listen(0, [
           :binary,
           packet: 4,
           active: false,
           ifaddr: {:local, Attach.socket_path()}
         ]) do
      {:ok, listen_socket} ->
        owner = self()
        acceptor = spawn_link(fn -> accept_loop(owner, listen_socket) end)
        # v0.62 M8.9: run attached commands in a supervised task (temporary
        # children) so a crashing or slow command cannot crash or block the
        # listener GenServer.
        {:ok, task_sup} = Task.Supervisor.start_link()
        Logger.info("attach listener started at #{Attach.socket_path()}")

        {:ok,
         %{listen_socket: listen_socket, acceptor: acceptor, token: token, task_sup: task_sup}}

      {:error, reason} ->
        {:stop, {:attach_listen_failed, reason}}
    end
  end

  @impl true
  def handle_info({:attach_request, request, socket}, %{token: token} = state) do
    case Attach.validate_request(request, token) do
      :ok ->
        # Off the listener process: a crash or a long-running command must not
        # take down or serialize the attach listener.
        Task.Supervisor.start_child(state.task_sup, fn ->
          reply(socket, run_attached_isolated(request.argv))
        end)

      {:error, reason} ->
        reply(socket, {:error, reason})
    end

    {:noreply, state}
  end

  def handle_info({:attach_invalid, reason, socket}, state) do
    reply(socket, {:error, reason})
    {:noreply, state}
  end

  def handle_info({:attach_accept_error, reason}, state) do
    {:stop, {:attach_accept_failed, reason}, state}
  end

  # Run the attached command with a crash barrier so a failing command returns a
  # structured error instead of taking down the task/listener.
  defp run_attached_isolated(argv) do
    {:ok, AllbertAssist.CLI.run_attached(argv)}
  rescue
    error -> {:error, {:command_crashed, Exception.message(error)}}
  catch
    kind, value -> {:error, {:command_crashed, inspect({kind, value})}}
  end

  defp reply(socket, response) do
    _ = :gen_tcp.send(socket, :erlang.term_to_binary(response))
    :gen_tcp.close(socket)
  end

  @impl true
  def terminate(_reason, %{listen_socket: listen_socket}) do
    :gen_tcp.close(listen_socket)
    Attach.remove_stale_socket()
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp accept_loop(owner, listen_socket) do
    case :gen_tcp.accept(listen_socket, @accept_timeout) do
      {:ok, socket} ->
        handle_socket(owner, socket)
        accept_loop(owner, listen_socket)

      {:error, :timeout} ->
        accept_loop(owner, listen_socket)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        send(owner, {:attach_accept_error, reason})
    end
  end

  defp handle_socket(owner, socket) do
    case :gen_tcp.recv(socket, 0, @recv_timeout) do
      {:ok, payload} ->
        case safe_binary_to_term(payload) do
          {:ok, request} -> send(owner, {:attach_request, request, socket})
          {:error, reason} -> send(owner, {:attach_invalid, reason, socket})
        end

      {:error, reason} ->
        send(owner, {:attach_invalid, reason, socket})
    end
  end

  defp safe_binary_to_term(payload) do
    {:ok, :erlang.binary_to_term(payload, [:safe])}
  rescue
    _error -> {:error, :invalid_term}
  end
end
