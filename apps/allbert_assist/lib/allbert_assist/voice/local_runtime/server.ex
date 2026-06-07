defmodule AllbertAssist.Voice.LocalRuntime.Server do
  @moduledoc """
  Bandit-backed loopback server for the Allbert local voice runtime.

  This is intentionally not supervised by default. Operators start it through
  the registered lifecycle action or CLI task after Settings Central enables
  the runtime and Security Central authorizes the lifecycle boundary.
  """

  alias AllbertAssist.Voice.LocalRuntime.Auth
  alias AllbertAssist.Voice.LocalRuntime.Config
  alias AllbertAssist.Voice.LocalRuntime.Router

  @spec start(keyword() | map()) ::
          {:ok, %{pid: pid(), config: Config.t(), token_path: String.t()}} | {:error, term()}
  def start(opts \\ []) do
    config = Config.build(opts)
    _token = Auth.ensure_token!()

    case Bandit.start_link(
           plug: {Router, config},
           ip: :loopback,
           port: config.port
         ) do
      {:ok, pid} ->
        {:ok, %{pid: pid, config: config, token_path: Auth.token_path()}}

      {:error, reason} ->
        {:error, {:local_voice_runtime_start_failed, reason}}
    end
  end
end
