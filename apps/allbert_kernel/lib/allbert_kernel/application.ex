defmodule AllbertKernel.Application do
  @moduledoc "OTP application owner for the kernel Pack supervision epoch."

  use Application

  @impl true
  def start(_type, _args), do: AllbertAssist.Pack.Supervisor.start_link([])
end
