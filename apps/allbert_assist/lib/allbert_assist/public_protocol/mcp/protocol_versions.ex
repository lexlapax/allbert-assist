defmodule AllbertAssist.PublicProtocol.Mcp.ProtocolVersions do
  @moduledoc """
  MCP protocol versions Allbert v0.51 accepts on public MCP surfaces.

  Hermes provides protocol framing, but Allbert owns the public ingress
  contract. Keep unsupported-version denial here so HTTP ingress and stdio
  adapter tests do not depend on dependency-specific negotiation fallbacks.
  """

  @supported ["2025-06-18", "2025-03-26"]
  @latest "2025-06-18"

  @type validation_error :: %{
          required(:code) => -32_602,
          required(:message) => String.t(),
          required(:data) => %{
            required(:requested) => String.t(),
            required(:supported) => [String.t(), ...]
          }
        }

  @type validation_result :: :ok | {:error, validation_error()}

  @spec supported() :: [String.t()]
  def supported, do: @supported

  @spec latest() :: String.t()
  def latest, do: @latest

  @spec supported?(term()) :: boolean()
  def supported?(version) when is_binary(version), do: version in @supported
  def supported?(_version), do: false

  @spec validate(term()) :: validation_result()
  def validate(version) when is_binary(version) do
    if supported?(version) do
      :ok
    else
      {:error,
       %{
         code: -32_602,
         message: "Unsupported MCP protocol version.",
         data: %{
           requested: version,
           supported: @supported
         }
       }}
    end
  end

  def validate(version) do
    {:error,
     %{
       code: -32_602,
       message: "Unsupported MCP protocol version.",
       data: %{
         requested: inspect(version),
         supported: @supported
       }
     }}
  end
end
