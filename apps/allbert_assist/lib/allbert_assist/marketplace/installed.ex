defmodule AllbertAssist.Marketplace.Installed do
  @moduledoc """
  Atomic `installed.json` state for Marketplace Lite.
  """

  alias AllbertAssist.Marketplace.Diagnostic
  alias AllbertAssist.Settings

  @empty_state %{"schema_version" => 1, "installed" => []}

  @spec list(keyword()) :: {:ok, [map()]} | {:error, map()}
  def list(opts \\ []) do
    with {:ok, state} <- read(opts) do
      {:ok, Map.get(state, "installed", [])}
    end
  end

  @spec read(keyword()) :: {:ok, map()} | {:error, map()}
  def read(opts \\ []) do
    path = state_path(opts)

    cond do
      not File.exists?(path) ->
        {:ok, @empty_state}

      File.regular?(path) ->
        with {:ok, body} <- File.read(path),
             {:ok, decoded} <- Jason.decode(body),
             :ok <- validate_state(decoded) do
          {:ok, decoded}
        else
          {:error, %Jason.DecodeError{} = error} -> {:error, invalid_json(error)}
          {:error, %{} = diagnostic} -> {:error, diagnostic}
          {:error, reason} -> {:error, read_failed(reason)}
        end

      true ->
        {:error,
         diagnostic(:installed_state_invalid, :installed_state_path_invalid,
           details: %{path: path}
         )}
    end
  end

  @spec write(map(), keyword()) :: :ok | {:error, map()}
  def write(state, opts \\ []) when is_map(state) do
    with :ok <- validate_state(state),
         path <- state_path(opts),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      tmp = path <> ".tmp"
      File.write!(tmp, Jason.encode!(state, pretty: true))
      File.rename!(tmp, path)
      :ok
    else
      {:error, %{} = diagnostic} ->
        {:error, diagnostic}

      {:error, reason} ->
        {:error,
         diagnostic(:installed_state_invalid, :installed_state_write_failed,
           details: %{reason: inspect(reason)}
         )}
    end
  end

  @spec with_lock(keyword(), (-> term())) :: term()
  def with_lock(opts, fun) when is_function(fun, 0) do
    lock = {__MODULE__, Path.expand(Keyword.get(opts, :home, AllbertAssist.Paths.home()))}
    :global.trans(lock, fun, [node()], :infinity)
  end

  @spec state_path(keyword()) :: String.t()
  def state_path(opts \\ []) do
    path =
      case Keyword.get(opts, :installed_state_path) do
        nil ->
          case Settings.get("marketplace.installed_state_path") do
            {:ok, path} -> path
            {:error, _reason} -> "<ALLBERT_HOME>/marketplace/installed.json"
          end

        path ->
          path
      end

    path
    |> resolve_home(opts)
    |> Path.expand()
  end

  def empty_state, do: @empty_state

  defp validate_state(%{"schema_version" => 1, "installed" => installed})
       when is_list(installed) do
    installed
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {record, index}, :ok ->
      case validate_record(record, index) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_state(%{"schema_version" => version}) do
    {:error,
     diagnostic(:installed_state_invalid, :unsupported_schema_version,
       pointer: "/schema_version",
       details: %{schema_version: version}
     )}
  end

  defp validate_state(_state),
    do: {:error, diagnostic(:installed_state_invalid, :invalid_installed_state, pointer: "/")}

  defp validate_record(record, index) when is_map(record) do
    required = ~w[entry_id version installed_at install_state install_target bundle_hash]

    case Enum.find(required, &(not Map.has_key?(record, &1))) do
      nil ->
        :ok

      key ->
        {:error,
         diagnostic(:installed_state_invalid, :missing_required_field,
           pointer: pointer(["installed", index, key])
         )}
    end
  end

  defp validate_record(_record, index),
    do:
      {:error,
       diagnostic(:installed_state_invalid, :invalid_installed_record,
         pointer: pointer(["installed", index])
       )}

  defp resolve_home(path, opts) do
    home = Keyword.get(opts, :home) || AllbertAssist.Paths.home()
    String.replace(path, "<ALLBERT_HOME>", home)
  end

  defp invalid_json(error) do
    diagnostic(:installed_state_invalid, :invalid_json,
      pointer: "/",
      details: %{message: Exception.message(error)}
    )
  end

  defp read_failed(reason) do
    diagnostic(:installed_state_invalid, :read_failed,
      pointer: "/",
      details: %{reason: inspect(reason)}
    )
  end

  defp pointer(segments), do: Diagnostic.pointer(segments)

  defp diagnostic(category, code, opts) do
    Diagnostic.new(category, code, message(code), opts)
  end

  defp message(:installed_state_path_invalid), do: "installed.json path is invalid"
  defp message(:installed_state_write_failed), do: "installed.json write failed"
  defp message(:unsupported_schema_version), do: "installed.json schema_version is unsupported"
  defp message(:invalid_installed_state), do: "installed.json is invalid"
  defp message(:missing_required_field), do: "installed record is missing a required field"
  defp message(:invalid_installed_record), do: "installed record is invalid"
  defp message(:invalid_json), do: "installed.json is not valid JSON"
  defp message(:read_failed), do: "installed.json could not be read"
end
