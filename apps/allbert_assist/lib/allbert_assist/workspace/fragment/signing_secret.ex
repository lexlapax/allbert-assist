defmodule AllbertAssist.Workspace.Fragment.SigningSecret do
  @moduledoc """
  Manages the system-owned HMAC secret for workspace FragmentEnvelope signatures.

  The secret is durable runtime state under Allbert Home, not ordinary operator
  configuration. Settings Central owns the schema key so the capability is
  visible, while this module owns the raw key material.
  """

  alias AllbertAssist.Paths

  @file_name "signing_secret"
  @previous_file_name "signing_secret.previous"
  @secret_bytes 32
  @file_mode 0o600
  @previous_secret_grace_seconds 60

  @type rotation_result :: %{
          required(:fingerprint) => String.t(),
          required(:previous_fingerprint) => String.t(),
          required(:previous_expires_at) => DateTime.t(),
          required(:overlap_seconds) => pos_integer(),
          required(:path) => String.t(),
          required(:rotated_at) => DateTime.t()
        }

  @doc "Return the canonical signing-secret path."
  @spec path() :: String.t()
  def path, do: Path.join(Paths.workspace_secrets_root(), @file_name)

  @doc false
  @spec previous_path() :: String.t()
  def previous_path, do: Path.join(Paths.workspace_secrets_root(), @previous_file_name)

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
  @spec rotate!() :: rotation_result()
  def rotate! do
    secret_path = path()
    File.mkdir_p!(Path.dirname(secret_path))
    old_secret = ensure!()
    rotated_at = DateTime.utc_now()
    previous_expires_at = DateTime.add(rotated_at, @previous_secret_grace_seconds, :second)
    secret = write_new_secret!(secret_path)
    write_previous_secret!(previous_path(), old_secret, previous_expires_at)

    %{
      fingerprint: fingerprint(secret),
      previous_fingerprint: fingerprint(old_secret),
      previous_expires_at: previous_expires_at,
      overlap_seconds: @previous_secret_grace_seconds,
      path: secret_path,
      rotated_at: rotated_at
    }
  end

  @doc "Replace the signing secret without raising."
  @spec rotate() :: {:ok, rotation_result()} | {:error, term()}
  def rotate do
    {:ok, rotate!()}
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  end

  @doc """
  Return active verification secrets, including the previous secret while its
  rotation grace window is still open.
  """
  @spec verification_secrets() :: {:ok, [String.t()]} | {:error, term()}
  def verification_secrets do
    current = ensure!()

    secrets =
      case read_previous_secret(DateTime.utc_now()) do
        {:ok, previous} when previous != current -> [current, previous]
        _other -> [current]
      end

    {:ok, secrets}
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

  defp write_previous_secret!(path, secret, expires_at) do
    payload =
      Jason.encode!(%{
        "secret" => secret,
        "expires_at" => DateTime.to_iso8601(expires_at)
      })

    tmp_path = "#{path}.tmp-#{System.unique_integer([:positive])}"

    File.write!(tmp_path, payload <> "\n")
    chmod_secret!(tmp_path)
    File.rename!(tmp_path, path)
    chmod_secret!(path)
  end

  defp read_previous_secret(now) do
    with {:ok, contents} <- File.read(previous_path()),
         {:ok, %{"secret" => secret, "expires_at" => expires_at}} <- Jason.decode(contents),
         true <- valid?(secret),
         {:ok, expires_at, _offset} <- DateTime.from_iso8601(expires_at) do
      if DateTime.compare(expires_at, now) == :gt do
        {:ok, secret}
      else
        cleanup_previous_secret()
        :expired
      end
    else
      {:error, :enoent} ->
        :missing

      _other ->
        cleanup_previous_secret()
        :invalid
    end
  end

  defp cleanup_previous_secret do
    case File.rm(previous_path()) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> :ok
    end
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
