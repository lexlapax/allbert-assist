defmodule AllbertAssist.Trace do
  @moduledoc """
  Markdown trace recorder for v0.01 runtime turns.

  M6 keeps traces plain and inspectable. The trace store writes markdown through
  `AllbertAssist.Memory` so the user can read, move, or delete trace files with
  ordinary filesystem tools.
  """

  alias AllbertAssist.Confirmations.ExternalRequestMetadata
  alias AllbertAssist.Confirmations.OnlineSkillMetadata
  alias AllbertAssist.Confirmations.PackageInstallMetadata
  alias AllbertAssist.Confirmations.ShellCommandMetadata
  alias AllbertAssist.Memory
  alias AllbertAssist.Security.Redactor

  @model_alias :local

  @type result :: {:ok, Memory.entry()} | {:disabled, :tracing_disabled} | {:error, term()}

  @doc "Return true when runtime trace recording is enabled."
  @spec enabled?() :: boolean()
  def enabled?(turn \\ %{}) do
    request_trace_enabled?(turn) || env_enabled?() || config_enabled?() || settings_enabled?(turn)
  end

  @doc "Record one runtime turn as markdown when tracing is enabled."
  @spec record_turn(map()) :: result()
  def record_turn(turn) when is_map(turn) do
    if enabled?(turn) do
      do_record_turn(turn)
    else
      {:disabled, :tracing_disabled}
    end
  end

  def record_turn(_turn), do: {:error, :invalid_trace_turn}

  defp do_record_turn(turn) do
    writer().(trace_attrs(turn))
  rescue
    exception ->
      {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end

  defp writer do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:writer, &Memory.append/1)
  end

  defp config_enabled? do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:enabled, false)
  end

  defp env_enabled? do
    System.get_env("ALLBERT_TRACE_ENABLED") in ["1", "true", "TRUE", "yes", "YES", "on", "ON"]
  end

  defp request_trace_enabled?(turn) do
    request = Map.get(turn, :request, %{})
    metadata = Map.get(request, :metadata, %{})

    Map.get(request, :trace) in [true, "true", "1"] ||
      Map.get(metadata, :trace) in [true, "true", "1"] ||
      Map.get(metadata, "trace") in [true, "true", "1"]
  end

  defp settings_enabled?(turn) do
    case AllbertAssist.Settings.get("runtime.trace_default") do
      {:ok, "enabled"} -> true
      {:ok, "denied_only"} -> denied_or_confirmation?(turn)
      _other -> false
    end
  rescue
    _exception -> false
  end

  defp denied_or_confirmation?(turn) do
    status =
      turn
      |> Map.get(:response, %{})
      |> Map.get(:status)

    status in [:denied, :needs_confirmation]
  end

  defp trace_attrs(turn) do
    response = Map.fetch!(turn, :response)
    input_signal = Map.fetch!(turn, :input_signal)
    response_signal = Map.fetch!(turn, :response_signal)
    request = Map.fetch!(turn, :request)

    %{
      category: :traces,
      summary: trace_summary(response, input_signal),
      body: trace_body(turn),
      source_signal_id: input_signal.id,
      actor: Map.get(request, :operator_id, "local"),
      agent: inspect(Map.get(turn, :agent, AllbertAssist.Agents.IntentAgent)),
      channel: Map.get(request, :channel, "unknown"),
      response_signal_id: response_signal.id
    }
  end

  defp trace_summary(response, input_signal) do
    action_name =
      response
      |> Map.get(:actions, [])
      |> List.first()
      |> action_name()

    "#{response.status} #{action_name} #{input_signal.id}"
  end

  defp trace_body(turn) do
    request = Map.fetch!(turn, :request)
    input_signal = Map.fetch!(turn, :input_signal)
    response_signal = Map.fetch!(turn, :response_signal)
    response = Map.fetch!(turn, :response)

    """
    ## Runtime Turn

    - Trace format: v0.01-m6
    - Input signal: #{input_signal.id}
    - Input signal type: #{input_signal.type}
    - Response signal: #{response_signal.id}
    - Response signal type: #{response_signal.type}
    - Channel: #{request.channel}
    - Operator: #{request.operator_id}
    - Agent: #{inspect(Map.get(turn, :agent, AllbertAssist.Agents.IntentAgent))}
    - Model alias: #{model_alias()}
    - Status: #{response.status}
    - Selected action: #{selected_action(response.actions)}
    - Permission decision: #{permission_decision(response.actions)}
    - Security metadata: #{security_metadata_summary(response.actions)}
    - Settings metadata: #{settings_metadata(response.actions)}
    - Confirmation metadata: #{confirmation_metadata_summary(response.actions)}
    - External request metadata: #{external_request_metadata_summary(response.actions)}
    - Package install metadata: #{package_install_metadata_summary(response.actions)}
    - Online skill metadata: #{online_skill_metadata_summary(response.actions)}
    - Shell command metadata: #{shell_command_metadata_summary(response.actions)}
    - Skill metadata: #{skill_metadata_summary(response.actions)}
    - Token estimate: #{token_estimate(request.text, response.message)}
    - Cost estimate: unavailable-local-model

    ## Input

    #{request.text}

    ## Response

    #{response.message}

    ## Actions

    ```elixir
    #{inspect(response.actions, pretty: true, limit: :infinity)}
    ```

    ## Skill Metadata

    #{skill_metadata_text(response.actions)}

    ## Security Metadata

    #{security_metadata_text(response.actions)}

    ## Confirmation Metadata

    #{confirmation_metadata_text(response.actions)}

    ## External Request Metadata

    #{external_request_metadata_text(response.actions)}

    ## Package Install Metadata

    #{package_install_metadata_text(response.actions)}

    ## Online Skill Metadata

    #{online_skill_metadata_text(response.actions)}

    ## Shell Command Metadata

    #{shell_command_metadata_text(response.actions)}

    ## Diagnostics

    #{diagnostics_text(response)}
    """
    |> String.trim()
  end

  defp model_alias do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:model_alias, @model_alias)
  end

  defp selected_action(actions) do
    actions
    |> List.first()
    |> action_name()
  end

  defp action_name(%{name: name}) when is_binary(name), do: name
  defp action_name(%{"name" => name}) when is_binary(name), do: name
  defp action_name(_action), do: "none"

  defp permission_decision(actions) do
    actions
    |> List.first()
    |> case do
      %{permission_decision: decision} -> inspect(Redactor.redact(decision), pretty: true)
      %{"permission_decision" => decision} -> inspect(Redactor.redact(decision), pretty: true)
      _action -> "none"
    end
  end

  defp security_metadata_summary(actions) do
    actions
    |> security_decision()
    |> case do
      %{decision: decision, risk: %{tier: risk}, trace: %{policy_source: source}} ->
        "#{decision} risk=#{risk} policy=#{source}"

      %{decision: decision} ->
        "#{decision}"

      _decision ->
        "none"
    end
  end

  defp security_metadata_text(actions) do
    actions
    |> security_decision()
    |> case do
      nil ->
        "none"

      decision ->
        decision
        |> Map.take([
          :permission,
          :decision,
          :requires_confirmation,
          :reason,
          :risk,
          :policy,
          :trace,
          :trust_boundary,
          :audit
        ])
        |> Redactor.redact()
        |> inspect(pretty: true, limit: :infinity)
    end
  end

  defp security_decision(actions) do
    actions
    |> List.first()
    |> case do
      %{permission_decision: %{risk: _risk} = decision} ->
        decision

      %{"permission_decision" => %{"risk" => _risk} = decision} ->
        atomize_security_decision(decision)

      _action ->
        nil
    end
  end

  defp atomize_security_decision(%{} = decision) do
    Map.new(decision, fn {key, value} -> {atomize_key(key), atomize_nested(value)} end)
  end

  defp atomize_nested(%{} = map), do: atomize_security_decision(map)
  defp atomize_nested(list) when is_list(list), do: Enum.map(list, &atomize_nested/1)
  defp atomize_nested(value), do: value

  defp atomize_key(key) when is_atom(key), do: key
  defp atomize_key("requires_confirmation"), do: :requires_confirmation
  defp atomize_key("trust_boundary"), do: :trust_boundary
  defp atomize_key("permission"), do: :permission
  defp atomize_key("decision"), do: :decision
  defp atomize_key("reason"), do: :reason
  defp atomize_key("risk"), do: :risk
  defp atomize_key("policy"), do: :policy
  defp atomize_key("trace"), do: :trace
  defp atomize_key("audit"), do: :audit
  defp atomize_key(key), do: key

  defp settings_metadata(actions) do
    actions
    |> List.first()
    |> case do
      %{settings_metadata: metadata} -> inspect(metadata, pretty: true)
      %{"settings_metadata" => metadata} -> inspect(metadata, pretty: true)
      _action -> "none"
    end
  end

  defp confirmation_metadata_summary(actions) do
    action = List.first(actions)

    case confirmation_metadata(action) do
      nil -> "none"
      metadata -> confirmation_summary(action, metadata)
    end
  end

  defp confirmation_summary(action, metadata) do
    id = map_value(metadata, :id) || map_value(action, :confirmation_id)
    status = map_value(metadata, :status) || map_value(metadata, :confirmation_status)
    target = map_value(metadata, :target_action) || action_name(action)
    origin = map_value(metadata, :origin) || %{}

    "#{id} status=#{status || "unknown"} target=#{target || "unknown"} origin=#{map_value(origin, :channel) || "unknown"}"
  end

  defp confirmation_metadata_text(actions) do
    action = List.first(actions)

    case confirmation_metadata(action) do
      nil ->
        "none"

      metadata ->
        %{
          confirmation_id: map_value(action, :confirmation_id),
          confirmation_metadata: metadata
        }
        |> Redactor.redact()
        |> inspect(pretty: true, limit: :infinity)
    end
  end

  defp confirmation_metadata(%{confirmation_metadata: metadata}) when not is_nil(metadata),
    do: metadata

  defp confirmation_metadata(%{"confirmation_metadata" => metadata}) when not is_nil(metadata),
    do: metadata

  defp confirmation_metadata(%{confirmation_id: id}) when not is_nil(id), do: %{id: id}
  defp confirmation_metadata(%{"confirmation_id" => id}) when not is_nil(id), do: %{"id" => id}
  defp confirmation_metadata(_action), do: nil

  defp external_request_metadata_summary(actions) do
    actions
    |> List.first()
    |> ExternalRequestMetadata.action_lines()
    |> first_line_or_none()
  end

  defp external_request_metadata_text(actions) do
    actions
    |> List.first()
    |> ExternalRequestMetadata.action_lines()
    |> lines_or_none()
  end

  defp package_install_metadata_summary(actions) do
    actions
    |> List.first()
    |> PackageInstallMetadata.action_lines()
    |> first_line_or_none()
  end

  defp package_install_metadata_text(actions) do
    actions
    |> List.first()
    |> PackageInstallMetadata.action_lines()
    |> lines_or_none()
  end

  defp online_skill_metadata_summary(actions) do
    actions
    |> List.first()
    |> OnlineSkillMetadata.action_lines()
    |> first_line_or_none()
  end

  defp online_skill_metadata_text(actions) do
    actions
    |> List.first()
    |> OnlineSkillMetadata.action_lines()
    |> lines_or_none()
  end

  defp shell_command_metadata_summary(actions) do
    actions
    |> List.first()
    |> ShellCommandMetadata.action_lines()
    |> first_line_or_none()
  end

  defp shell_command_metadata_text(actions) do
    actions
    |> List.first()
    |> ShellCommandMetadata.action_lines()
    |> lines_or_none()
  end

  defp first_line_or_none(lines) do
    case lines do
      [] -> "none"
      [line | _rest] -> line
    end
  end

  defp lines_or_none(lines) do
    lines
    |> case do
      [] -> "none"
      lines -> Enum.join(lines, "\n")
    end
  end

  defp skill_metadata_summary(actions) do
    actions
    |> skill_metadata()
    |> case do
      %{selected_skill: selected_skill, source_scope: source_scope, trust_status: trust_status} ->
        "#{selected_skill} (#{source_scope}, #{trust_status})"

      %{selected_skill: selected_skill, status: status} ->
        "#{selected_skill} (#{status})"

      _metadata ->
        "none"
    end
  end

  defp skill_metadata_text(actions) do
    actions
    |> skill_metadata()
    |> case do
      nil -> "none"
      metadata -> inspect(metadata, pretty: true, limit: :infinity)
    end
  end

  defp skill_metadata(actions) do
    actions
    |> List.first()
    |> case do
      %{skill_metadata: metadata} -> metadata
      %{"skill_metadata" => metadata} -> metadata
      _action -> nil
    end
  end

  defp token_estimate(input, output) do
    [input, output]
    |> Enum.map(&estimate_text_tokens/1)
    |> Enum.sum()
  end

  defp estimate_text_tokens(text) when is_binary(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  defp estimate_text_tokens(_text), do: 0

  defp diagnostics_text(%{diagnostics: []}), do: "none"
  defp diagnostics_text(%{diagnostics: diagnostics}), do: inspect(diagnostics, pretty: true)
  defp diagnostics_text(_response), do: "none"

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp map_value(_map, _key), do: nil
end
