defmodule AllbertAssist.PublicProtocol.StdioGuard do
  @moduledoc """
  Keeps public stdio protocol streams free of non-protocol logger output.

  Elixir's default Logger handler writes to standard output in this runtime.
  Public stdio protocol entrypoints must reserve stdout for protocol frames, so
  they call this before application startup can emit logs.
  """

  @saved_level_key {__MODULE__, :saved_logger_level}

  @doc "Silence Logger while application startup may reset handlers to stdout."
  @spec silence_stdout!() :: :ok
  def silence_stdout! do
    configure_default_handler()
    save_logger_level()
    _result = :logger.set_primary_config(:level, :none)
    :ok
  end

  @doc "Route the default console logger to stderr, falling back to silence."
  @spec protect_stdout!() :: :ok
  def protect_stdout! do
    with :ok <- configure_default_handler(),
         :ok <- route_stdout_handlers(),
         :ok <- restore_logger_level() do
      :ok
    else
      _reason -> silence_logger()
    end
  end

  defp route_stdout_handlers do
    :logger.get_handler_ids()
    |> Enum.filter(&stdio_handler?/1)
    |> Enum.reduce_while(:ok, fn handler_id, :ok ->
      case route_stdout_handler(handler_id) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp configure_default_handler do
    handler_config =
      :logger
      |> Application.get_env(:default_handler, [])
      |> normalize_default_handler_config()
      |> Keyword.update(
        :config,
        %{type: :standard_error},
        &Map.put(Map.new(&1), :type, :standard_error)
      )

    Application.put_env(:logger, :default_handler, handler_config)
    :ok
  end

  defp normalize_default_handler_config(config) when is_list(config), do: config
  defp normalize_default_handler_config(config) when is_map(config), do: Map.to_list(config)
  defp normalize_default_handler_config(_config), do: []

  defp stdio_handler?(handler_id) do
    case :logger.get_handler_config(handler_id) do
      {:ok, %{module: :logger_std_h}} -> true
      _other -> false
    end
  end

  defp route_stdout_handler(handler_id) do
    with {:ok, handler} <- :logger.get_handler_config(handler_id),
         false <- stderr_handler?(handler),
         :ok <- :logger.remove_handler(handler_id),
         :ok <- :logger.add_handler(handler_id, :logger_std_h, stderr_config(handler)) do
      :ok
    else
      true -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp stderr_handler?(%{config: %{type: :standard_error}}), do: true
  defp stderr_handler?(_handler), do: false

  defp stderr_config(handler) do
    handler
    |> Map.delete(:id)
    |> Map.delete(:module)
    |> Map.update(:config, %{type: :standard_error}, &Map.put(&1, :type, :standard_error))
  end

  defp save_logger_level do
    unless Process.get(@saved_level_key) do
      Process.put(@saved_level_key, current_logger_level())
    end

    :ok
  end

  defp current_logger_level do
    :logger.get_primary_config()
    |> Map.get(:level, :all)
  end

  defp restore_logger_level do
    case Process.delete(@saved_level_key) do
      nil -> :ok
      level -> :logger.set_primary_config(:level, level)
    end
  end

  defp silence_logger do
    _result = :logger.set_primary_config(:level, :none)
    :ok
  end
end
