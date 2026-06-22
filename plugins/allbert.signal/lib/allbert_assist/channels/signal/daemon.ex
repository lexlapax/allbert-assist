defmodule AllbertAssist.Channels.Signal.Daemon do
  @moduledoc false

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings.Secrets

  @key_file_exts ~w[db json config profile key]

  def daemon_child_spec(settings, opts \\ []) when is_map(settings) do
    Supervisor.child_spec(
      {MuonTrap.Daemon,
       [
         daemon_path(settings),
         daemon_args(settings),
         daemon_opts(settings, opts)
       ]},
      id: Keyword.get(opts, :id, :signal_cli_daemon)
    )
  end

  def daemon_args(settings) when is_map(settings) do
    ["--config", data_dir(settings), "daemon"]
    |> Kernel.++(control_args(settings))
  end

  def daemon_path(settings), do: nonblank(Map.get(settings, "daemon_path"), "signal-cli")

  def data_dir(settings), do: nonblank(Map.get(settings, "data_dir"), default_data_dir())

  def socket_path(settings), do: nonblank(Map.get(settings, "socket_path"), default_socket_path())

  def default_data_dir, do: Path.join(Paths.home(), "signal")
  def default_socket_path, do: Path.join(default_data_dir(), "signal-cli.sock")

  def ensure_custody!(settings) when is_map(settings) do
    dir = data_dir(settings)
    File.mkdir_p!(dir)
    chmod(dir, 0o700)

    dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.each(&chmod_key_file/1)

    %{data_dir: dir, directory_mode: file_mode(dir), key_files: key_file_modes(dir)}
  end

  def control_diagnostics(settings) when is_map(settings) do
    case Map.get(settings, "control_mode", "socket") do
      "socket" ->
        socket_diagnostics(settings)

      "loopback_http" ->
        loopback_http_diagnostics(settings)

      "stub" ->
        %{mode: "stub", local_only?: true, ok?: true, diagnostics: []}

      other ->
        %{mode: other, local_only?: false, ok?: false, diagnostics: [:invalid_control_mode]}
    end
  end

  def client_opts(settings, extra_opts \\ []) do
    mode = Map.get(settings, "control_mode", "socket")

    [
      mode: client_mode(mode),
      socket_path: socket_path(settings),
      base_url: Map.get(settings, "loopback_http_base_url"),
      auth_ref: Map.get(settings, "control_auth_ref")
    ]
    |> Keyword.merge(extra_opts)
  end

  defp control_args(%{"control_mode" => "loopback_http"} = settings) do
    base_url = Map.get(settings, "loopback_http_base_url", "")
    uri = URI.parse(base_url)
    host = uri.host || "127.0.0.1"
    port = uri.port || 8080
    ["--http", "#{host}:#{port}"]
  end

  defp control_args(%{"control_mode" => "stub"}), do: ["--socket", default_socket_path()]
  defp control_args(settings), do: ["--socket", socket_path(settings)]

  defp daemon_opts(_settings, opts) do
    [
      log_output: Keyword.get(opts, :log_output, :debug),
      log_prefix: Keyword.get(opts, :log_prefix, "signal-cli: ")
    ]
  end

  defp socket_diagnostics(settings) do
    path = socket_path(settings)
    mode = file_mode(path)

    diagnostics =
      []
      |> maybe_add(not local_path?(path), :signal_socket_not_local_path)
      |> maybe_add(not is_nil(mode) and mode != 0o600, :signal_socket_not_0600)

    %{
      mode: "socket",
      socket_path: path,
      socket_mode: mode,
      local_only?: local_path?(path),
      ok?: diagnostics == [],
      diagnostics: diagnostics
    }
  end

  defp loopback_http_diagnostics(settings) do
    base_url = Map.get(settings, "loopback_http_base_url")
    uri = URI.parse(to_string(base_url || ""))
    auth_ref = Map.get(settings, "control_auth_ref")
    auth_configured? = Secrets.status(auth_ref) == :configured

    diagnostics =
      []
      |> maybe_add(missing_loopback_base_url?(base_url), :missing_loopback_http_base_url)
      |> maybe_add(uri.scheme not in ["http", "https"], :signal_control_endpoint_not_http)
      |> maybe_add(uri.host not in ["127.0.0.1", "localhost", "::1"], :not_loopback)
      |> maybe_add(not auth_configured?, :missing_control_auth)

    %{
      mode: "loopback_http",
      base_url: base_url,
      local_only?: uri.host in ["127.0.0.1", "localhost", "::1"],
      auth_configured?: auth_configured?,
      ok?: diagnostics == [],
      diagnostics: diagnostics
    }
  end

  defp key_file_modes(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.filter(&key_file?/1)
    |> Map.new(fn path -> {Path.relative_to(path, dir), file_mode(path)} end)
  end

  defp key_file?(path) do
    ext = path |> Path.extname() |> String.trim_leading(".")
    ext in @key_file_exts
  end

  defp chmod_key_file(path) do
    if key_file?(path), do: chmod(path, 0o600)
  end

  defp chmod(path, mode) do
    case File.chmod(path, mode) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp file_mode(path) do
    case File.stat(path) do
      {:ok, stat} -> Bitwise.band(stat.mode, 0o777)
      {:error, _reason} -> nil
    end
  end

  defp local_path?(path) when is_binary(path) do
    path = Path.expand(path)
    home = Path.expand(Paths.home())
    String.starts_with?(path, home) or String.starts_with?(path, System.tmp_dir!())
  end

  defp missing_loopback_base_url?(value) when value in [nil, ""], do: true
  defp missing_loopback_base_url?(_value), do: false

  defp maybe_add(diagnostics, true, diagnostic), do: diagnostics ++ [diagnostic]
  defp maybe_add(diagnostics, false, _diagnostic), do: diagnostics

  defp nonblank(value, default) when is_binary(value) do
    case String.trim(value) do
      "" -> default
      trimmed -> trimmed
    end
  end

  defp nonblank(_value, default), do: default

  defp client_mode("loopback_http"), do: :loopback_http
  defp client_mode("stub"), do: :stub
  defp client_mode(_mode), do: :socket
end
