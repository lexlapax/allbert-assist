defmodule Mix.Tasks.Allbert.HexAudit do
  @moduledoc """
  Enforce a security-capable Hex version, then audit the shared lockfile.

      mix allbert.hex_audit

  Hex 2.5.0 is the minimum because earlier `hex.audit` implementations do not
  evaluate the current security-advisory database.
  """

  use Mix.Task

  @shortdoc "Audit locked dependencies with a security-capable Hex release"
  @minimum_hex Version.parse!("2.5.0")
  @hex_audit_task "hex" <> "." <> "audit"

  @impl Mix.Task
  def run(args) do
    version = version_provider().()
    require_supported_hex!(version)
    audit_runner().(args)
  end

  defp require_supported_hex!(version) when is_binary(version) do
    case Version.parse(version) do
      {:ok, parsed} ->
        if Version.compare(parsed, @minimum_hex) in [:eq, :gt],
          do: :ok,
          else: unsupported_hex!(version)

      _ ->
        unsupported_hex!(version)
    end
  end

  defp require_supported_hex!(version), do: unsupported_hex!(version)

  @spec unsupported_hex!(term()) :: no_return()
  defp unsupported_hex!(version) do
    found = if is_binary(version), do: version, else: "not installed"

    Mix.raise(
      "Hex 2.5.0 or newer is required for security-advisory auditing " <>
        "(found #{found}). Run `mix local.hex --force`, then retry."
    )
  end

  defp version_provider do
    Application.get_env(:allbert_assist, :hex_version_provider, fn ->
      case Application.spec(:hex, :vsn) do
        nil -> nil
        version -> to_string(version)
      end
    end)
  end

  defp audit_runner do
    Application.get_env(:allbert_assist, :hex_audit_runner, fn args ->
      {output, status} =
        System.cmd("mix", [@hex_audit_task | args],
          cd: File.cwd!(),
          stderr_to_stdout: true
        )

      IO.write(output)

      if status != 0 do
        Mix.raise("Hex advisory audit failed with status #{status}")
      end

      :ok
    end)
  end
end
