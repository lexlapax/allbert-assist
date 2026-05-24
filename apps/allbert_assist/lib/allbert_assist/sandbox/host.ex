defmodule AllbertAssist.Sandbox.Host do
  @moduledoc """
  Host facts used by the v0.36 sandbox backend resolver.
  """

  @enforce_keys [:os, :arch]
  defstruct [:os, :arch, :macos_version]

  @type os :: :macos | :linux | :windows | :unknown
  @type arch :: :arm64 | :x86_64 | :unknown
  @type t :: %__MODULE__{
          os: os(),
          arch: arch(),
          macos_version: {non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil
        }

  @spec current() :: t()
  def current do
    %__MODULE__{
      os: current_os(),
      arch: current_arch(),
      macos_version: macos_version()
    }
  end

  @spec macos_apple_container_capable?(t()) :: boolean()
  def macos_apple_container_capable?(%__MODULE__{
        os: :macos,
        arch: :arm64,
        macos_version: {major, _minor, _patch}
      }),
      do: major >= 26

  def macos_apple_container_capable?(_host), do: false

  defp current_os do
    case :os.type() do
      {:unix, :darwin} -> :macos
      {:unix, :linux} -> :linux
      {:win32, _name} -> :windows
      _other -> :unknown
    end
  end

  defp current_arch do
    arch = :erlang.system_info(:system_architecture) |> to_string() |> String.downcase()

    cond do
      String.contains?(arch, "aarch64") -> :arm64
      String.contains?(arch, "arm64") -> :arm64
      String.contains?(arch, "x86_64") -> :x86_64
      String.contains?(arch, "amd64") -> :x86_64
      true -> :unknown
    end
  end

  defp macos_version do
    if current_os() == :macos do
      case System.cmd("sw_vers", ["-productVersion"], stderr_to_stdout: true) do
        {version, 0} -> parse_version(version)
        _other -> nil
      end
    end
  rescue
    _exception -> nil
  end

  defp parse_version(version) do
    parts =
      version
      |> String.trim()
      |> String.split(".")
      |> Enum.map(&parse_int/1)

    case parts do
      [major, minor, patch | _rest] -> {major, minor, patch}
      [major, minor] -> {major, minor, 0}
      [major] -> {major, 0, 0}
      _other -> nil
    end
  end

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> 0
    end
  end
end
