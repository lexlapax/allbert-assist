defmodule AllbertAssist.Settings.Secrets do
  @moduledoc """
  Encrypted local secret store for user-supplied Settings Central credentials.
  """

  alias AllbertAssist.PublicProtocol.TokenAuth
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Audit
  alias AllbertAssist.Settings.KeyCustody
  alias AllbertAssist.Settings.Schema
  alias AllbertAssist.Settings.Store
  alias AllbertAssist.Settings.YamlCodec

  @aad "settings:v1"
  @cipher "aes-256-gcm"
  @key_bytes 32
  @nonce_bytes 12
  @tag_bytes 16

  def secrets_path, do: Path.join(Store.root(), "secrets.yml.enc")
  def key_path, do: Path.join(Store.root(), ".settings_key")

  def put_secret(secret_ref, value, context \\ %{})

  def put_secret(secret_ref, value, context) when is_binary(value) do
    with :ok <- validate_secret_ref(secret_ref),
         old_status <- status(secret_ref),
         {:ok, key} <- master_key(),
         {:ok, plaintext} <- read_plaintext(key),
         updated_plaintext <- put_plaintext_secret(plaintext, secret_ref, value, context),
         :ok <- write_plaintext(key, updated_plaintext),
         :ok <- maybe_write_setting_ref(secret_ref, context) do
      KeyCustody.invalidate(secret_ref)
      diagnostics = audit_secret(secret_ref, old_status, :configured, context)
      {:ok, %{secret_ref: secret_ref, status: :configured, diagnostics: diagnostics}}
    end
  end

  def put_secret(_secret_ref, _value, _context),
    do: {:error, {:invalid_secret_value, :not_a_string}}

  def get_secret(secret_ref, context \\ %{}), do: KeyCustody.fetch(secret_ref, context)

  def list_secret_status(namespace_or_opts \\ []) do
    namespace = namespace(namespace_or_opts)

    case KeyCustody.list_secret_status(namespace) do
      {:ok, statuses} ->
        {:ok, statuses}

      {:decrypt_failed, _reason} ->
        {:ok, [%{secret_ref: namespace || "secret://", status: :decrypt_failed}]}
    end
  end

  def delete_secret(secret_ref, _context \\ %{}) do
    with :ok <- validate_secret_ref(secret_ref),
         {:ok, key} <- master_key(),
         {:ok, plaintext} <- read_plaintext(key),
         updated <- delete_plaintext_secret(plaintext, secret_ref),
         :ok <- write_plaintext(key, updated) do
      KeyCustody.invalidate(secret_ref)
      {:ok, %{secret_ref: secret_ref, status: :missing}}
    end
  end

  defp audit_secret(secret_ref, old_status, new_status, context) do
    case Audit.append_secret(secret_ref, old_status, new_status, context) do
      {:ok, path} -> [%{source: :settings_audit, audit_path: path}]
      {:error, reason} -> [%{source: :settings_audit, error: inspect(reason)}]
    end
  end

  def redact(key_or_ref, value) do
    if redacted_key?(key_or_ref), do: redacted_value(value), else: value
  end

  def status(secret_ref) do
    KeyCustody.status(secret_ref)
  end

  @doc false
  def load_plaintext_for_custody do
    with {:ok, key} <- master_key(),
         {:ok, plaintext} <- read_plaintext(key) do
      {:ok, plaintext}
    end
  end

  @doc false
  def plaintext_entries_for_custody(plaintext) do
    plaintext = ensure_plaintext_shape(plaintext)

    plaintext
    |> statuses_from_plaintext(nil)
    |> Enum.flat_map(fn %{secret_ref: secret_ref, status: :configured} ->
      case get_plaintext_secret(plaintext, secret_ref) do
        {:ok, value} -> [{secret_ref, value}]
        {:error, _reason} -> []
      end
    end)
  end

  def validate_secret_ref(secret_ref) when is_binary(secret_ref) do
    if provider_ref?(secret_ref) or channel_ref?(secret_ref) or mcp_ref?(secret_ref) or
         public_protocol_ref?(secret_ref) do
      :ok
    else
      {:error, {:invalid_secret_ref, secret_ref}}
    end
  end

  def validate_secret_ref(secret_ref), do: {:error, {:invalid_secret_ref, secret_ref}}

  defp master_key do
    cond do
      env_key = System.get_env("ALLBERT_SETTINGS_MASTER_KEY") ->
        decode_key(env_key, :env)

      config_key = Keyword.get(Store.app_config(), :master_key) ->
        decode_key(config_key, :config)

      production?() ->
        {:error, {:settings_master_key_missing, :production}}

      true ->
        local_key()
    end
  end

  defp decode_key(key, _source) when is_binary(key) and byte_size(key) == @key_bytes,
    do: {:ok, key}

  defp decode_key(key, source) when is_binary(key) do
    case Base.decode64(key) do
      {:ok, decoded} when byte_size(decoded) == @key_bytes -> {:ok, decoded}
      _other -> {:error, {:invalid_settings_master_key, source}}
    end
  end

  defp decode_key(_key, source), do: {:error, {:invalid_settings_master_key, source}}

  defp local_key do
    Store.ensure_root!()
    path = key_path()

    if File.exists?(path) do
      path
      |> File.read()
      |> case do
        {:ok, key} -> decode_key(String.trim(key), :local_file)
        {:error, reason} -> {:error, {:settings_master_key_read_failed, reason}}
      end
    else
      key = :crypto.strong_rand_bytes(@key_bytes)

      with :ok <- File.write(path, Base.encode64(key) <> "\n"),
           :ok <- chmod_key(path) do
        {:ok, key}
      else
        {:error, reason} -> {:error, {:settings_master_key_write_failed, reason}}
      end
    end
  end

  defp chmod_key(path) do
    case File.chmod(path, 0o600) do
      :ok -> :ok
      {:error, :enotsup} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_plaintext(key) do
    if File.exists?(secrets_path()) do
      decrypt_file(key)
    else
      {:ok, %{"version" => 1, "secrets" => %{}}}
    end
  end

  defp write_plaintext(key, plaintext) do
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)
    plaintext_yaml = YamlCodec.encode!(plaintext)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        nonce,
        plaintext_yaml,
        @aad,
        @tag_bytes,
        true
      )

    envelope = %{
      "version" => 1,
      "cipher" => @cipher,
      "nonce" => Base.encode64(nonce),
      "tag" => Base.encode64(tag),
      "ciphertext" => Base.encode64(ciphertext)
    }

    Store.write_atomic(secrets_path(), YamlCodec.encode!(envelope))
  rescue
    exception ->
      {:error, {:secret_write_failed, {exception.__struct__, Exception.message(exception)}}}
  end

  defp decrypt_file(key) do
    with {:ok, envelope} <- YamlCodec.read_file(secrets_path()),
         {:ok, nonce} <- decode_envelope_field(envelope, "nonce"),
         {:ok, tag} <- decode_envelope_field(envelope, "tag"),
         {:ok, ciphertext} <- decode_envelope_field(envelope, "ciphertext"),
         :ok <- validate_envelope(envelope),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, @aad, tag, false),
         {:ok, decoded} <- YamlCodec.read_string(plaintext) do
      {:ok, decoded}
    else
      {:error, {:settings_parse_failed, reason}} ->
        {:error, {:secret_decrypt_failed, reason}}

      {:error, reason} ->
        {:error, {:secret_decrypt_failed, reason}}

      :error ->
        {:error, {:secret_decrypt_failed, :authentication_failed}}
    end
  rescue
    exception ->
      {:error, {:secret_decrypt_failed, {exception.__struct__, Exception.message(exception)}}}
  end

  defp validate_envelope(%{"version" => 1, "cipher" => @cipher}), do: :ok
  defp validate_envelope(_envelope), do: {:error, :invalid_secret_envelope}

  defp decode_envelope_field(envelope, key) do
    envelope
    |> Map.fetch(key)
    |> case do
      {:ok, value} when is_binary(value) -> Base.decode64(value)
      {:ok, _value} -> {:error, {:invalid_secret_envelope_field, key}}
      :error -> {:error, {:missing_secret_envelope_field, key}}
    end
  end

  defp put_plaintext_secret(plaintext, secret_ref, value, context) do
    {:ok, path} = plaintext_secret_path(secret_ref)
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    entry = %{
      "value" => value,
      "updated_at" => now,
      "actor" => context_value(context, :actor, "local"),
      "channel" => context_value(context, :channel, "unknown")
    }

    plaintext
    |> ensure_plaintext_shape()
    |> put_in_secret_path(path, entry)
  end

  defp get_plaintext_secret(plaintext, secret_ref) do
    with {:ok, path} <- plaintext_secret_path(secret_ref),
         %{"value" => value} <- get_in(plaintext, ["secrets" | path]) do
      {:ok, value}
    else
      _other -> {:error, {:secret_not_found, secret_ref}}
    end
  end

  defp delete_plaintext_secret(plaintext, secret_ref) do
    {:ok, path} = plaintext_secret_path(secret_ref)
    put_in_secret_path(ensure_plaintext_shape(plaintext), path, nil)
  end

  defp statuses_from_plaintext(plaintext, nil) do
    [
      secret_statuses(plaintext, "providers", &provider_secret_status/1),
      secret_statuses(plaintext, "channels", &channel_secret_status/1),
      secret_statuses(plaintext, "mcp", &mcp_secret_status/1),
      secret_statuses(plaintext, "public_protocol", &public_protocol_secret_status/1)
    ]
    |> List.flatten()
  end

  defp secret_statuses(plaintext, key, callback) do
    case get_in(plaintext, ["secrets", key]) do
      entries when is_map(entries) -> Enum.flat_map(entries, callback)
      _other -> []
    end
  end

  defp provider_secret_status({provider, attrs}) do
    if is_map(attrs) and is_map(attrs["api_key"]) do
      [%{secret_ref: "secret://providers/#{provider}/api_key", status: :configured}]
    else
      []
    end
  end

  defp channel_secret_status({channel, attrs}) when is_map(attrs) do
    attrs
    |> Enum.filter(fn {_name, entry} -> is_map(entry) end)
    |> Enum.map(fn {name, _entry} ->
      %{secret_ref: "secret://channels/#{channel}/#{name}", status: :configured}
    end)
  end

  defp channel_secret_status(_entry), do: []

  defp mcp_secret_status({server, attrs}) when is_map(attrs) do
    attrs
    |> Enum.filter(fn {_name, entry} -> is_map(entry) end)
    |> Enum.map(fn {name, _entry} ->
      %{secret_ref: "secret://mcp/#{server}/#{name}", status: :configured}
    end)
  end

  defp mcp_secret_status(_entry), do: []

  defp public_protocol_secret_status({surface, clients}) when is_map(clients) do
    Enum.flat_map(clients, fn
      {client_id, attrs} when is_map(attrs) ->
        attrs
        |> Enum.filter(fn {_name, entry} -> is_map(entry) end)
        |> Enum.map(fn {name, _entry} ->
          %{
            secret_ref: "secret://public_protocol/#{surface}/#{client_id}/#{name}",
            status: :configured
          }
        end)

      _entry ->
        []
    end)
  end

  defp public_protocol_secret_status(_entry), do: []

  defp ensure_plaintext_shape(%{"version" => 1, "secrets" => secrets}) when is_map(secrets) do
    %{"version" => 1, "secrets" => secrets}
  end

  defp ensure_plaintext_shape(_plaintext), do: %{"version" => 1, "secrets" => %{}}

  defp put_in_secret_path(plaintext, path, nil) do
    update_in(plaintext, ["secrets" | path], fn _value -> nil end)
  end

  defp put_in_secret_path(plaintext, path, value) do
    put_nested(plaintext, ["secrets" | path], value)
  end

  defp put_nested(map, [key], value), do: Map.put(map, key, value)

  defp put_nested(map, [key | rest], value) do
    child =
      map
      |> Map.get(key, %{})
      |> case do
        child when is_map(child) -> child
        _other -> %{}
      end

    Map.put(map, key, put_nested(child, rest, value))
  end

  defp provider_from_ref(secret_ref) do
    case Regex.run(~r/^secret:\/\/providers\/([A-Za-z0-9_-]+)\/api_key$/, secret_ref) do
      [_, provider] -> {:ok, provider}
      _match -> {:error, {:invalid_secret_ref, secret_ref}}
    end
  end

  defp channel_from_ref(secret_ref) do
    case Regex.run(~r/^secret:\/\/channels\/([A-Za-z0-9_-]+)\/([A-Za-z0-9_-]+)$/, secret_ref) do
      [_, channel, name] -> {:ok, channel, name}
      _match -> {:error, {:invalid_secret_ref, secret_ref}}
    end
  end

  defp mcp_from_ref(secret_ref) do
    case Regex.run(~r/^secret:\/\/mcp\/([A-Za-z0-9_-]+)\/([A-Za-z0-9_-]+)$/, secret_ref) do
      [_, server, name] -> {:ok, server, name}
      _match -> {:error, {:invalid_secret_ref, secret_ref}}
    end
  end

  defp public_protocol_from_ref(secret_ref) do
    TokenAuth.parse_secret_ref(secret_ref)
  end

  defp plaintext_secret_path(secret_ref) do
    cond do
      provider_ref?(secret_ref) ->
        with {:ok, provider} <- provider_from_ref(secret_ref) do
          {:ok, ["providers", provider, "api_key"]}
        end

      channel_ref?(secret_ref) ->
        with {:ok, channel, name} <- channel_from_ref(secret_ref) do
          {:ok, ["channels", channel, name]}
        end

      mcp_ref?(secret_ref) ->
        with {:ok, server, name} <- mcp_from_ref(secret_ref) do
          {:ok, ["mcp", server, name]}
        end

      public_protocol_ref?(secret_ref) ->
        with {:ok, surface, client_id, name} <- public_protocol_from_ref(secret_ref) do
          {:ok, ["public_protocol", surface, client_id, name]}
        end

      true ->
        {:error, {:invalid_secret_ref, secret_ref}}
    end
  end

  defp maybe_write_setting_ref(secret_ref, context) do
    if provider_ref?(secret_ref) do
      with {:ok, provider} <- provider_from_ref(secret_ref),
           {:ok, _resolved} <-
             Settings.put(
               "providers.#{provider}.api_key_ref",
               secret_ref,
               Map.put(context, :audit?, false)
             ) do
        :ok
      end
    else
      :ok
    end
  end

  defp provider_ref?(secret_ref) when is_binary(secret_ref),
    do: Regex.match?(~r/^secret:\/\/providers\/[A-Za-z0-9_-]+\/api_key$/, secret_ref)

  defp provider_ref?(_secret_ref), do: false

  defp channel_ref?(secret_ref) when is_binary(secret_ref),
    do: Regex.match?(~r/^secret:\/\/channels\/[A-Za-z0-9_-]+\/[A-Za-z0-9_-]+$/, secret_ref)

  defp channel_ref?(_secret_ref), do: false

  defp mcp_ref?(secret_ref) when is_binary(secret_ref),
    do: Regex.match?(~r/^secret:\/\/mcp\/[A-Za-z0-9_-]+\/[A-Za-z0-9_-]+$/, secret_ref)

  defp mcp_ref?(_secret_ref), do: false

  defp public_protocol_ref?(secret_ref) when is_binary(secret_ref),
    do: TokenAuth.public_protocol_secret_ref?(secret_ref)

  defp public_protocol_ref?(_secret_ref), do: false

  defp namespace(opts) when is_list(opts), do: Keyword.get(opts, :namespace)
  defp namespace(namespace) when is_binary(namespace), do: namespace
  defp namespace(_namespace), do: nil

  defp context_value(context, key, default) do
    context
    |> Map.get(key)
    |> Kernel.||(Map.get(context, Atom.to_string(key)))
    |> Kernel.||(default)
    |> to_string()
  end

  defp redacted_value(value) when is_binary(value) and value != "", do: "[REDACTED]"
  defp redacted_value(_value), do: "[REDACTED]"

  defp redacted_key?(key_or_ref) when is_binary(key_or_ref) do
    Schema.sensitive_key?(key_or_ref) or String.starts_with?(key_or_ref, "secret://")
  end

  defp redacted_key?(_key_or_ref), do: false

  defp production? do
    Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :prod
  end
end
