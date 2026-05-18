defmodule AllbertAssist.Workspace.Fragment.SigningSecret do
  @moduledoc """
  Manages the system-owned HMAC secret for workspace FragmentEnvelope signatures.

  The secret is durable runtime state under Allbert Home, not ordinary operator
  configuration. Settings Central owns the schema key so the capability is
  visible, while this module owns the raw key material.
  """

  alias AllbertAssist.Paths

  @file_name "signing_secret"
  @secret_bytes 32
  @file_mode 0o600

  @doc "Return the canonical signing-secret path."
  @spec path() :: String.t()
  def path, do: Path.join(Paths.workspace_secrets_root(), @file_name)

  @doc "Ensure a signing secret exists and return the raw 32-byte hex secret."
  @spec ensure!() :: String.t()
  def ensure! do
    secret_path = path()
    File.mkdir_p!(Path.dirname(secret_path))

    case File.read(secret_path) do
      {:ok, contents} ->
        contents
        |> String.trim()
        |> validate_existing!(secret_path)

      {:error, :enoent} ->
        write_new_secret!(secret_path)

      {:error, reason} ->
        raise "failed to read workspace fragment signing secret at #{secret_path}: #{inspect(reason)}"
    end
  end

  @doc "Ensure a signing secret exists without raising."
  @spec ensure() :: {:ok, String.t()} | {:error, term()}
  def ensure do
    {:ok, ensure!()}
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  end

  @doc "Read the signing secret without creating one."
  @spec read() :: {:ok, String.t()} | {:error, term()}
  def read do
    secret_path = path()

    with {:ok, contents} <- File.read(secret_path) do
      secret = String.trim(contents)
      if valid?(secret), do: {:ok, secret}, else: {:error, :invalid_signing_secret}
    end
  end

  @doc "Replace the signing secret with fresh key material."
  @spec rotate!() :: %{fingerprint: String.t(), path: String.t(), rotated_at: DateTime.t()}
  def rotate! do
    secret_path = path()
    File.mkdir_p!(Path.dirname(secret_path))
    secret = write_new_secret!(secret_path)

    %{
      fingerprint: fingerprint(secret),
      path: secret_path,
      rotated_at: DateTime.utc_now()
    }
  end

  @doc "Replace the signing secret without raising."
  @spec rotate() ::
          {:ok, %{fingerprint: String.t(), path: String.t(), rotated_at: DateTime.t()}}
          | {:error, term()}
  def rotate do
    {:ok, rotate!()}
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  end

  @doc "Return true when the value is a 32-byte hex secret."
  @spec valid?(term()) :: boolean()
  def valid?(secret) when is_binary(secret), do: Regex.match?(~r/^[0-9a-fA-F]{64}$/, secret)
  def valid?(_secret), do: false

  @doc "Return a short non-secret fingerprint suitable for logs and CLI output."
  @spec fingerprint(String.t()) :: String.t()
  def fingerprint(secret) when is_binary(secret) do
    :crypto.hash(:sha256, secret)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  defp validate_existing!(secret, secret_path) do
    if valid?(secret) do
      chmod_secret!(secret_path)
      secret
    else
      raise "workspace fragment signing secret at #{secret_path} is not a 32-byte hex secret"
    end
  end

  defp write_new_secret!(secret_path) do
    secret = new_secret()
    tmp_path = "#{secret_path}.tmp-#{System.unique_integer([:positive])}"

    File.write!(tmp_path, secret <> "\n")
    chmod_secret!(tmp_path)
    File.rename!(tmp_path, secret_path)
    chmod_secret!(secret_path)

    secret
  end

  defp new_secret do
    @secret_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp chmod_secret!(path) do
    case File.chmod(path, @file_mode) do
      :ok ->
        :ok

      {:error, reason} ->
        raise "failed to chmod workspace fragment signing secret #{path}: #{inspect(reason)}"
    end
  end
end
