defmodule AllbertAssist.Pack.CandidateBuilder.ChannelRows do
  @moduledoc false

  alias AllbertAssist.Pack.CandidateBuilder.RowFamilies
  alias AllbertAssist.Pack.{PathSegment, Row, RowSchemas, ValidationDiagnostic}

  @spec build([map()]) :: {:ok, RowFamilies.t()} | {:error, [ValidationDiagnostic.t()]}
  def build(plugins) when is_list(plugins) do
    plugins
    |> Enum.filter(&(&1.status == :enabled))
    |> Enum.flat_map(fn plugin -> Enum.map(plugin.channels, &{plugin, &1}) end)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{}}, fn {{plugin, descriptor}, index}, {:ok, rows} ->
      with {:ok, authority} <- authority(plugin, descriptor) do
        normalized = reference!(descriptor, authority)
        payload = RowSchemas.canonical_projection(normalized)

        row = %Row{
          schema_version: 1,
          kind: :channels,
          owner_id: plugin.plugin_id,
          identity: %{namespace: :channel_id, value: payload["channel_id"]},
          order: %{namespace: :legacy_index, value: index},
          payload_schema: :channel_descriptor_v1,
          payload: payload,
          source_authority: RowSchemas.source_authority_projection(normalized),
          m0_payload_sha256: nil
        }

        {:cont, {:ok, Map.update(rows, plugin.plugin_id, [row], &(&1 ++ [row]))}}
      else
        _ -> {:halt, invalid(:invalid_channel_descriptor)}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, %{RowFamilies.empty() | channels: rows}}
      error -> error
    end
  rescue
    _ -> invalid(:invalid_channel_rows)
  end

  def build(_plugins), do: invalid(:invalid_channel_input)

  defp reference!(descriptor, authority) do
    payload = %{
      "channel_id" => field(descriptor, :channel_id),
      "module" => field(descriptor, :adapter)
    }

    placeholder = Map.put(payload, "projection_sha256", String.duplicate("0", 64))

    digest =
      RowSchemas.reference_digest_for!(:channel_descriptor_v1, %RowSchemas.Input{
        payload: placeholder,
        source_authority: authority
      })

    RowSchemas.normalize!(:channel_descriptor_v1, %RowSchemas.Input{
      payload: Map.put(payload, "projection_sha256", digest),
      source_authority: authority
    })
  end

  defp authority(plugin, descriptor) when is_map(descriptor) do
    with true <- field(descriptor, :plugin_id) == plugin.plugin_id,
         {:ok, session_strategy} <- session_strategy(field(descriptor, :session_strategy)),
         {:ok, child_spec} <- child_spec(field(descriptor, :child_spec)) do
      {:ok,
       %{
         "plugin_id" => field(descriptor, :plugin_id),
         "channel_id" => field(descriptor, :channel_id),
         "adapter" => field(descriptor, :adapter),
         "provider" => field(descriptor, :provider),
         "source" => field(descriptor, :source),
         "status" => field(descriptor, :status),
         "settings_prefix" => field(descriptor, :settings_prefix),
         "identity_map_key" => field(descriptor, :identity_map_key),
         "primitives" => field(descriptor, :primitives, []),
         "threading" => field(descriptor, :threading),
         "streaming" => field(descriptor, :streaming),
         "session_strategy" => session_strategy,
         "trust_class" => field(descriptor, :trust_class),
         "secret_refs" => field(descriptor, :secret_refs, []),
         "summary_fields" => field(descriptor, :summary_fields, []),
         "can_create_thread" => field(descriptor, :can_create_thread),
         "reply_key_type" => field(descriptor, :reply_key_type),
         "quote_ttl_ms" => field(descriptor, :quote_ttl_ms),
         "status_update_mode" => field(descriptor, :status_update_mode),
         "child_spec" => child_spec
       }}
    else
      _ -> :error
    end
  end

  defp authority(_plugin, _descriptor), do: :error

  defp session_strategy(nil), do: {:ok, nil}

  defp session_strategy({strategy, opts}) when is_atom(strategy) and is_list(opts) do
    if Keyword.keyword?(opts) do
      {:ok,
       %{
         "strategy" => strategy,
         "options" =>
           Enum.map(opts, fn {key, value} -> %{"key" => key, "value" => closed(value)} end)
       }}
    else
      :error
    end
  end

  defp session_strategy(_value), do: :error

  defp child_spec(nil), do: {:ok, nil}

  defp child_spec({module, options}) when is_atom(module) and is_list(options) do
    {:ok, %{"kind" => "module_options", "module" => module, "options" => closed(options)}}
  end

  defp child_spec(_value), do: :error

  defp closed(value) when is_nil(value) or is_boolean(value) or is_number(value), do: value
  defp closed(value) when is_binary(value), do: value
  defp closed(value) when is_atom(value), do: module_name(value)
  defp closed(value) when is_list(value), do: Enum.map(value, &closed/1)

  defp closed(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, nested} -> {closed_key(key), closed(nested)} end)
  end

  defp closed(_value), do: raise(ArgumentError)

  defp closed_key(value) when is_binary(value), do: value
  defp closed_key(value) when is_atom(value), do: Atom.to_string(value)
  defp closed_key(_value), do: raise(ArgumentError)

  defp field(map, key, default \\ nil) do
    case {Map.fetch(map, key), Map.fetch(map, Atom.to_string(key))} do
      {{:ok, value}, :error} -> value
      {:error, {:ok, value}} -> value
      {:error, :error} -> default
      {{:ok, value}, {:ok, value}} -> value
      _ -> raise(ArgumentError)
    end
  end

  defp module_name(value), do: value |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

  defp invalid(reason),
    do:
      {:error,
       [
         %ValidationDiagnostic{
           schema_version: 1,
           code: :invalid_value,
           path: [%PathSegment{schema_version: 1, kind: :field, value: "channels"}],
           owner: nil,
           detail: %{reason: reason}
         }
       ]}
end
