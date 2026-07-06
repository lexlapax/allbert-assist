defmodule AllbertAssist.FirstModel.Hardware do
  @moduledoc """
  Hardware-floor check for the curated default model (v0.62 M4, Locked
  Decision 9). Below the floor, first-run degrades to BYOK rather than pulling
  a multi-GB model the machine cannot run.
  """

  @doc "Total system RAM in GB (best-effort per OS), or nil if undetectable."
  @spec total_ram_gb() :: number() | nil
  def total_ram_gb do
    case :os.type() do
      {:unix, :darwin} -> darwin_ram_gb()
      {:unix, _linux} -> linux_ram_gb()
      _other -> nil
    end
  end

  @doc "True when total RAM meets the given floor (GB). Unknown RAM passes (fail-open toward offering the model, with the pull itself still confirmation-gated)."
  @spec meets_floor?(number()) :: boolean()
  def meets_floor?(floor_gb) do
    case total_ram_gb() do
      nil -> true
      gb -> gb >= floor_gb
    end
  end

  defp darwin_ram_gb do
    case System.cmd("sysctl", ["-n", "hw.memsize"], stderr_to_stdout: true) do
      {out, 0} ->
        case Integer.parse(String.trim(out)) do
          {bytes, _} -> Float.round(bytes / 1_073_741_824, 1)
          :error -> nil
        end

      _error ->
        nil
    end
  rescue
    _error -> nil
  end

  defp linux_ram_gb do
    with {:ok, meminfo} <- File.read("/proc/meminfo"),
         [_, kb] <- Regex.run(~r/MemTotal:\s+(\d+)\s+kB/, meminfo) do
      Float.round(String.to_integer(kb) / 1_048_576, 1)
    else
      _error -> nil
    end
  end
end
