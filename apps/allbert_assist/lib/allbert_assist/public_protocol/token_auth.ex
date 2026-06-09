defmodule AllbertAssist.PublicProtocol.TokenAuth do
  @moduledoc """
  Settings-Secrets backed bearer tokens for v0.51 HTTP public protocol surfaces.
  """

  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets

  @surfaces %{
    "mcp_http" => "mcp_server.clients",
    "openai_api" => "openai_api.clients"
  }

  @token_name "bearer_token"
  @redacted "[REDACTED]"

  @type surface :: :mcp_http | :openai_api | String.t()
  @type token_result :: %{
          surface: String.t(),
          client_id: String.t(),
          token_ref: String.t(),
          token: String.t(),
          redacted_token: String.t()
        }

  @spec create(surface(), String.t(), map()) :: {:ok, token_result()} | {:error, term()}
  def create(surface, client_id, context \\ %{}) do
    put_token(surface, client_id, new_token(), context, :create)
  end

  @spec rotate(surface(), String.t(), map()) :: {:ok, token_result()} | {:error, term()}
  def rotate(surface, client_id, context \\ %{}) do
    put_token(surface, client_id, new_token(), context, :rotate)
  end

  @spec revoke(surface(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def revoke(surface, client_id, context \\ %{}) do
    with {:ok, surface} <- normalize_surface(surface),
         :ok <- validate_client_id(client_id),
         token_ref <- token_ref(surface, client_id),
         {:ok, _secret} <- Secrets.delete_secret(token_ref, context),
         {:ok, clients} <- client_settings(surface),
         entry <- Map.get(clients, client_id, default_client(token_ref)),
         updated <- Map.put(clients, client_id, Map.put(entry, "enabled", false)),
         {:ok, _resolved} <- Settings.put(settings_key(surface), updated, %{audit?: false}) do
      {:ok,
       %{
         surface: surface,
         client_id: client_id,
         token_ref: token_ref,
         status: :revoked,
         redacted_token: @redacted
       }}
    end
  end

  @spec list(surface()) :: {:ok, [map()]} | {:error, term()}
  def list(surface) do
    with {:ok, surface} <- normalize_surface(surface),
         {:ok, clients} <- client_settings(surface) do
      clients
      |> Enum.map(fn {client_id, entry} ->
        token_ref = Map.get(entry, "token_ref", token_ref(surface, client_id))

        %{
          surface: surface,
          client_id: client_id,
          enabled: Map.get(entry, "enabled", false),
          token_ref: token_ref,
          token_status: Secrets.status(token_ref),
          rate_limit: Map.get(entry, "rate_limit", default_rate_limit()),
          redacted_token: @redacted
        }
      end)
      |> Enum.sort_by(& &1.client_id)
      |> then(&{:ok, &1})
    end
  end

  @spec verify(surface(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def verify(surface, client_id, token) when is_binary(token) do
    with {:ok, surface} <- normalize_surface(surface),
         :ok <- validate_client_id(client_id),
         {:ok, clients} <- client_settings(surface),
         {:ok, entry} <- fetch_enabled_client(clients, client_id),
         token_ref <- Map.get(entry, "token_ref", token_ref(surface, client_id)),
         {:ok, expected} <- Secrets.get_secret(token_ref),
         true <- Plug.Crypto.secure_compare(token, expected) do
      {:ok,
       %{
         surface: surface,
         client_id: client_id,
         token_ref: token_ref,
         rate_limit: Map.get(entry, "rate_limit", default_rate_limit())
       }}
    else
      false -> {:error, :invalid_token}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify(_surface, _client_id, _token), do: {:error, :invalid_token}

  @spec token_ref(surface(), String.t()) :: String.t()
  def token_ref(surface, client_id) do
    surface = surface |> normalize_surface!()
    "secret://public_protocol/#{surface}/#{client_id}/#{@token_name}"
  end

  @spec allowed_surface?(term()) :: boolean()
  def allowed_surface?(surface), do: match?({:ok, _surface}, normalize_surface(surface))

  @spec validate_client_id(term()) :: :ok | {:error, {:invalid_client_id, term()}}
  def validate_client_id(client_id) when is_binary(client_id) do
    if Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/, client_id) do
      :ok
    else
      {:error, {:invalid_client_id, client_id}}
    end
  end

  def validate_client_id(client_id), do: {:error, {:invalid_client_id, client_id}}

  @spec public_protocol_secret_ref?(term()) :: boolean()
  def public_protocol_secret_ref?(value) when is_binary(value) do
    match?({:ok, _surface, _client_id, _name}, parse_secret_ref(value))
  end

  def public_protocol_secret_ref?(_value), do: false

  @spec parse_secret_ref(String.t()) ::
          {:ok, String.t(), String.t(), String.t()} | {:error, {:invalid_secret_ref, String.t()}}
  def parse_secret_ref(secret_ref) when is_binary(secret_ref) do
    case Regex.run(
           ~r/^secret:\/\/public_protocol\/([A-Za-z0-9_-]+)\/([A-Za-z0-9_-]+)\/([A-Za-z0-9_-]+)$/,
           secret_ref
         ) do
      [_, surface, client_id, name] ->
        with {:ok, surface} <- normalize_surface(surface),
             :ok <- validate_client_id(client_id),
             true <- name == @token_name do
          {:ok, surface, client_id, name}
        else
          _other -> {:error, {:invalid_secret_ref, secret_ref}}
        end

      _match ->
        {:error, {:invalid_secret_ref, secret_ref}}
    end
  end

  defp put_token(surface, client_id, token, context, _operation) do
    with {:ok, surface} <- normalize_surface(surface),
         :ok <- validate_client_id(client_id),
         token_ref <- token_ref(surface, client_id),
         {:ok, _secret} <- Secrets.put_secret(token_ref, token, context),
         {:ok, clients} <- client_settings(surface),
         entry <- Map.merge(default_client(token_ref), Map.get(clients, client_id, %{})),
         updated <-
           Map.put(
             clients,
             client_id,
             Map.merge(entry, %{"enabled" => true, "token_ref" => token_ref})
           ),
         {:ok, _resolved} <- Settings.put(settings_key(surface), updated, %{audit?: false}) do
      {:ok,
       %{
         surface: surface,
         client_id: client_id,
         token_ref: token_ref,
         token: token,
         redacted_token: @redacted
       }}
    end
  end

  defp fetch_enabled_client(clients, client_id) do
    case Map.fetch(clients, client_id) do
      {:ok, %{"enabled" => true} = entry} -> {:ok, entry}
      {:ok, _entry} -> {:error, :client_disabled}
      :error -> {:error, :unknown_client}
    end
  end

  defp client_settings(surface) do
    case Settings.get(settings_key(surface)) do
      {:ok, clients} when is_map(clients) -> {:ok, clients}
      {:ok, other} -> {:error, {:invalid_clients_setting, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp settings_key(surface), do: Map.fetch!(@surfaces, surface)

  defp default_client(token_ref) do
    %{"enabled" => true, "token_ref" => token_ref, "rate_limit" => default_rate_limit()}
  end

  defp default_rate_limit, do: %{"limit" => 60, "period_ms" => 60_000, "burst" => 10}

  defp normalize_surface(surface) when is_atom(surface),
    do: normalize_surface(Atom.to_string(surface))

  defp normalize_surface(surface) when is_binary(surface) do
    if Map.has_key?(@surfaces, surface),
      do: {:ok, surface},
      else: {:error, {:invalid_surface, surface}}
  end

  defp normalize_surface(surface), do: {:error, {:invalid_surface, surface}}

  defp normalize_surface!(surface) do
    case normalize_surface(surface) do
      {:ok, normalized} ->
        normalized

      {:error, reason} ->
        raise ArgumentError, "invalid public protocol surface: #{inspect(reason)}"
    end
  end

  defp new_token do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
