defmodule AllbertAssist.Objectives.Fanout.ReceiptSecret do
  @moduledoc false

  alias AllbertAssist.Paths

  @file_mode 0o600

  def ensure! do
    path = Path.join([Paths.home(), "objectives", "receipt_secret"])
    File.mkdir_p!(Path.dirname(path))

    case File.read(path) do
      {:ok, secret} ->
        secret = String.trim(secret)
        if byte_size(secret) == 64, do: secret, else: raise("invalid fanout receipt secret")

      {:error, :enoent} ->
        write_new!(path)

      {:error, reason} ->
        raise "failed to read fanout receipt secret: #{inspect(reason)}"
    end
  end

  defp write_new!(path) do
    secret = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

    case File.open(path, [:write, :exclusive], fn io -> IO.binwrite(io, secret <> "\n") end) do
      {:ok, :ok} ->
        File.chmod!(path, @file_mode)
        secret

      {:error, :eexist} ->
        ensure!()

      {:error, reason} ->
        raise "failed to create fanout receipt secret: #{inspect(reason)}"
    end
  end
end
