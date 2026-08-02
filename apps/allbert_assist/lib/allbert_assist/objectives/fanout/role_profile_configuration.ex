defmodule AllbertAssist.Objectives.Fanout.RoleProfileConfiguration do
  @moduledoc """
  Canonical, redacted configuration binding for one fan-out model role.

  This pure value boundary binds the selected profile, role, endpoint identity,
  secret-reference identity, and closed request/protocol controls. It never
  accepts resolved credentials or arbitrary request options and owns no model
  selection, disclosure, provider call, Objective, or durable state. A separate
  domain binds the ordered per-attempt digests so a repair with a shorter
  deadline cannot be represented as the initial request configuration alone.
  """

  alias AllbertAssist.Objectives.CanonicalJSON

  @version 1
  @digest_domain "allbert:fanout-role-profile-configuration:v1\0"
  @attempt_set_digest_domain "allbert:fanout-role-profile-attempt-set:v1\0"
  @roles ~w[fanout_manager fanout_review fanout_synthesis]
  @transport_keys ~w[
    base_url response_schema_sha256 temperature max_output_tokens
    receive_timeout_ms total_timeout_ms max_retries structured_output_mode json_repair
  ]
  @extra_keys ~w[
    phase policy_version review_protocol_version rule_catalog_version
    rule_catalog_sha256 rule_group_catalog_version rule_group_catalog_sha256
    group_id revision_rule_ids_sha256
  ]
  @profile_contract_fields ~w[aliases capabilities media temperature max_tokens timeout_ms]a

  @type error_reason ::
          :invalid_fanout_role
          | :invalid_fanout_role_profile
          | :invalid_fanout_role_transport
          | :invalid_fanout_role_protocol_extras

  @doc "Return the domain-separated SHA-256 for one closed redacted role configuration."
  @spec digest(atom() | String.t(), map(), map(), map()) ::
          {:ok, String.t()} | {:error, error_reason()}
  def digest(role, profile, transport, extras \\ %{})

  def digest(role, profile, transport, extras)
      when is_map(profile) and is_map(transport) and is_map(extras) do
    with {:ok, projection} <- projection(role, profile, transport, extras) do
      {:ok, sha256(@digest_domain <> CanonicalJSON.encode(projection))}
    end
  end

  def digest(_role, _profile, _transport, _extras),
    do: {:error, :invalid_fanout_role_profile}

  @doc "Bind an ordered non-empty set of exact per-attempt configuration digests."
  @spec attempt_set_digest([String.t()]) ::
          {:ok, String.t()} | {:error, :invalid_fanout_role_attempt_set}
  def attempt_set_digest(digests) when is_list(digests) and digests != [] do
    if Enum.all?(digests, &sha256?/1) do
      projection = %{
        "version" => 1,
        "attempts" =>
          digests
          |> Enum.with_index(1)
          |> Enum.map(fn {digest, attempt} ->
            %{"attempt" => attempt, "configuration_sha256" => digest}
          end)
      }

      {:ok, sha256(@attempt_set_digest_domain <> CanonicalJSON.encode(projection))}
    else
      {:error, :invalid_fanout_role_attempt_set}
    end
  end

  def attempt_set_digest(_digests), do: {:error, :invalid_fanout_role_attempt_set}

  @doc false
  @spec projection(atom() | String.t(), map(), map(), map()) ::
          {:ok, map()} | {:error, error_reason()}
  def projection(role, profile, transport, extras \\ %{})

  def projection(role, profile, transport, extras)
      when is_map(profile) and is_map(transport) and is_map(extras) do
    with {:ok, role} <- normalize_role(role),
         {:ok, transport} <- normalize_transport(transport),
         {:ok, extras} <- normalize_extras(extras),
         {:ok, profile} <- normalize_profile(profile, transport) do
      {:ok,
       %{
         "version" => @version,
         "role" => role,
         "profile" => profile,
         "transport" => Map.delete(transport, "base_url"),
         "protocol" => extras
       }}
    end
  end

  def projection(_role, _profile, _transport, _extras),
    do: {:error, :invalid_fanout_role_profile}

  defp normalize_role(role) when is_atom(role), do: normalize_role(Atom.to_string(role))

  defp normalize_role(role) when role in @roles, do: {:ok, role}
  defp normalize_role(_role), do: {:error, :invalid_fanout_role}

  defp normalize_profile(profile, transport) do
    with {:ok, name} <- identifier(profile_field(profile, :name)),
         {:ok, provider} <- identifier_or_unknown(profile_field(profile, :provider)),
         {:ok, provider_type} <- identifier_or_unknown(profile_field(profile, :provider_type)),
         {:ok, endpoint_kind} <-
           identifier_or_unknown(profile_field(profile, :provider_endpoint_kind)),
         {:ok, model} <- identifier(profile_field(profile, :model)),
         {:ok, configured_endpoint} <- endpoint(profile_field(profile, :provider_base_url)),
         {:ok, effective_endpoint} <-
           endpoint(transport["base_url"] || profile_field(profile, :provider_base_url)),
         {:ok, profile_contract} <- profile_contract(profile) do
      {:ok,
       %{
         "name" => name,
         "provider" => provider,
         "provider_type" => provider_type,
         "endpoint_kind" => endpoint_kind,
         "configured_endpoint" => configured_endpoint,
         "effective_endpoint" => effective_endpoint,
         "model" => model,
         "secret_reference_sha256" => secret_reference_sha256(profile),
         "profile_contract_sha256" => sha256(CanonicalJSON.encode(profile_contract))
       }}
    else
      _invalid -> {:error, :invalid_fanout_role_profile}
    end
  end

  defp normalize_transport(transport) do
    with {:ok, normalized} <- normalize_keys(transport),
         true <- Enum.sort(Map.keys(normalized)) == Enum.sort(@transport_keys),
         true <- valid_optional_url?(normalized["base_url"]),
         true <- sha256?(normalized["response_schema_sha256"]),
         true <- is_number(normalized["temperature"]),
         true <- positive_integer?(normalized["max_output_tokens"]),
         true <- positive_integer?(normalized["receive_timeout_ms"]),
         true <- optional_positive_integer?(normalized["total_timeout_ms"]),
         true <- non_negative_integer?(normalized["max_retries"]),
         true <- normalized["structured_output_mode"] in ["json_schema", :json_schema],
         true <- is_boolean(normalized["json_repair"]) do
      {:ok,
       normalized
       |> Map.update!("structured_output_mode", &to_string/1)
       |> Map.update!("base_url", &normalize_optional_url/1)}
    else
      _invalid -> {:error, :invalid_fanout_role_transport}
    end
  end

  defp normalize_extras(extras) do
    with {:ok, normalized} <- normalize_keys(extras),
         true <- Enum.all?(Map.keys(normalized), &(&1 in @extra_keys)),
         true <- Enum.all?(normalized, fn {_key, value} -> closed_extra?(value) end),
         {:ok, normalized} <- normalize_json_value(normalized),
         true <- valid_extra_digests?(normalized) do
      {:ok, normalized}
    else
      _invalid -> {:error, :invalid_fanout_role_protocol_extras}
    end
  end

  defp profile_contract(profile) do
    @profile_contract_fields
    |> Map.new(&{Atom.to_string(&1), profile_field(profile, &1)})
    |> normalize_json_value()
  end

  defp secret_reference_sha256(profile) do
    case profile_field(profile, :provider_api_key_ref) || profile_field(profile, :api_key_ref) do
      value when is_binary(value) and value != "" -> sha256(value)
      _missing -> nil
    end
  end

  defp endpoint(nil), do: {:ok, nil}

  defp endpoint(url) when is_binary(url) do
    uri = URI.parse(String.trim(url))

    if is_binary(uri.scheme) and uri.scheme != "" and is_binary(uri.host) and uri.host != "" do
      {:ok,
       %{
         "scheme" => String.downcase(uri.scheme),
         "host" => String.downcase(uri.host),
         "port" => uri.port,
         "path_sha256" => sha256(uri.path || "")
       }}
    else
      {:error, :invalid_endpoint}
    end
  end

  defp endpoint(_url), do: {:error, :invalid_endpoint}

  defp identifier(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp identifier(value) when is_binary(value) and value != "", do: {:ok, value}
  defp identifier(_value), do: {:error, :invalid_identifier}

  defp identifier_or_unknown(nil), do: {:ok, "unknown"}
  defp identifier_or_unknown(value), do: identifier(value)

  defp normalize_keys(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      case normalize_key(key) do
        {:ok, key} when not is_map_key(normalized, key) ->
          {:cont, {:ok, Map.put(normalized, key, value)}}

        _invalid_or_duplicate ->
          {:halt, {:error, :invalid_keys}}
      end
    end)
  end

  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(key) when is_binary(key) and key != "", do: {:ok, key}
  defp normalize_key(_key), do: {:error, :invalid_key}

  defp normalize_json_value(value)
       when is_nil(value) or is_binary(value) or is_boolean(value) or is_number(value),
       do: {:ok, value}

  defp normalize_json_value(value) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp normalize_json_value(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, normalized} ->
      case normalize_json_value(value) do
        {:ok, value} -> {:cont, {:ok, [value | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_json_value(value) when is_map(value) do
    with {:ok, normalized} <- normalize_keys(value) do
      normalize_json_map(normalized)
    end
  end

  defp normalize_json_value(_value), do: {:error, :invalid_json_value}

  defp normalize_json_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, &normalize_json_entry/2)
  end

  defp normalize_json_entry({key, nested}, {:ok, normalized}) do
    case normalize_json_value(nested) do
      {:ok, nested} -> {:cont, {:ok, Map.put(normalized, key, nested)}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp closed_extra?(value)
       when is_nil(value) or is_binary(value) or is_boolean(value) or is_number(value),
       do: true

  defp closed_extra?(value) when is_atom(value), do: true
  defp closed_extra?(values) when is_list(values), do: Enum.all?(values, &closed_extra?/1)
  defp closed_extra?(_value), do: false

  defp valid_extra_digests?(extras) do
    extras
    |> Enum.filter(fn {key, _value} -> String.ends_with?(key, "_sha256") end)
    |> Enum.all?(fn {_key, value} -> sha256?(value) end)
  end

  defp valid_optional_url?(nil), do: true
  defp valid_optional_url?(value), do: is_binary(value) and String.trim(value) != ""
  defp normalize_optional_url(nil), do: nil
  defp normalize_optional_url(value), do: String.trim(value)
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp optional_positive_integer?(nil), do: true
  defp optional_positive_integer?(value), do: positive_integer?(value)
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp profile_field(profile, key) do
    Map.get(profile, key) || Map.get(profile, Atom.to_string(key))
  end

  defp sha256?(value) when is_binary(value) and byte_size(value) == 64 do
    match?({:ok, <<_::256>>}, Base.decode16(value, case: :lower))
  end

  defp sha256?(_value), do: false

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
