defmodule AllbertAssist.Portability.Envelope do
  @moduledoc """
  Versioned Allbert Home export envelope.
  """

  @envelope_version 1

  @doc "Current export envelope format version."
  @spec envelope_version() :: 1
  def envelope_version, do: @envelope_version

  @doc "Validate the minimum envelope shape and version."
  @spec validate(map()) :: :ok | {:error, term()}
  def validate(%{"envelope_version" => @envelope_version, "settings" => settings})
      when is_map(settings) do
    :ok
  end

  def validate(%{"envelope_version" => version}) do
    {:error, {:unsupported_envelope_version, version, @envelope_version}}
  end

  def validate(_other), do: {:error, :invalid_envelope}
end
