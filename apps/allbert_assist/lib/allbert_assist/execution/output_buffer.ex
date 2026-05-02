defmodule AllbertAssist.Execution.OutputBuffer do
  @moduledoc false

  defstruct limit: 65_536,
            bytes: 0,
            chunks: [],
            truncated?: false

  @type t :: %__MODULE__{
          limit: pos_integer(),
          bytes: non_neg_integer(),
          chunks: [binary()],
          truncated?: boolean()
        }

  def new(limit) when is_integer(limit) and limit > 0 do
    %__MODULE__{limit: limit}
  end

  def append(%__MODULE__{truncated?: true} = buffer, _chunk), do: buffer

  def append(%__MODULE__{} = buffer, chunk) do
    chunk = IO.iodata_to_binary(chunk)
    remaining = buffer.limit - buffer.bytes

    cond do
      remaining <= 0 ->
        %{buffer | truncated?: true}

      byte_size(chunk) <= remaining ->
        %{buffer | bytes: buffer.bytes + byte_size(chunk), chunks: [chunk | buffer.chunks]}

      true ->
        kept = binary_part(chunk, 0, remaining)

        %{
          buffer
          | bytes: buffer.limit,
            chunks: [kept | buffer.chunks],
            truncated?: true
        }
    end
  end

  def output(%__MODULE__{} = buffer) do
    buffer.chunks
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end
end

defimpl Collectable, for: AllbertAssist.Execution.OutputBuffer do
  alias AllbertAssist.Execution.OutputBuffer

  def into(buffer) do
    collector = fn
      buffer, {:cont, chunk} -> OutputBuffer.append(buffer, chunk)
      buffer, :done -> buffer
      _buffer, :halt -> :ok
    end

    {buffer, collector}
  end
end
