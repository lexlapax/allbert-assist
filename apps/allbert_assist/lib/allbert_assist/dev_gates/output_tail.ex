defmodule AllbertAssist.DevGates.OutputTail do
  @moduledoc """
  Collectable used by development gates to keep a bounded output tail.

  The release gate can stream child output for operator visibility while still
  retaining a bounded tail for diagnostic evidence.
  """

  defstruct limit: 12_000, stream?: false, tail: ""

  def new(opts \\ []) do
    %__MODULE__{
      limit: Keyword.get(opts, :limit, 12_000),
      stream?: Keyword.get(opts, :stream?, false)
    }
  end

  def append(%__MODULE__{} = collector, chunk) when is_binary(chunk) do
    if collector.stream? do
      IO.write(chunk)
    end

    %{collector | tail: trim(collector.tail <> chunk, collector.limit)}
  end

  def trim(output, limit) when is_binary(output) and is_integer(limit) and limit > 0 do
    if byte_size(output) > limit do
      binary_part(output, byte_size(output) - limit, limit)
    else
      output
    end
  end
end

defimpl Collectable, for: AllbertAssist.DevGates.OutputTail do
  def into(collector) do
    {collector,
     fn
       collector, {:cont, chunk} ->
         AllbertAssist.DevGates.OutputTail.append(collector, chunk)

       collector, :done ->
         collector.tail

       _collector, :halt ->
         :ok
     end}
  end
end
