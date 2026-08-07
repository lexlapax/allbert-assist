defmodule AllbertAssist.Confirmations do
  @moduledoc """
  Durable confirmation request domain.

  Runtime-facing approval and denial enter through registered actions. This
  module is the plain Elixir facade those actions use behind the boundary.
  """

  alias AllbertAssist.Confirmations.Store
  alias AllbertAssist.Maps
  alias AllbertAssist.Runtime.Redactor

  @adapter_unavailable_note "Approved, but not executed: this historical target had no adapter when it was created. New v0.10 external-network requests use the confirmed Req adapter."

  defdelegate root(), to: Store
  defdelegate ensure_root!(), to: Store

  @doc """
  Create a durable confirmation with the caller's exact readiness context.

  A complete objective/step pair supplied by an internal domain is classified
  for durable objective verification. Fan-out-child binding is never inferred
  here; objective provenance is taken from that same carried context.
  """
  @spec create(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(attrs, effect_context, opts \\ [])

  def create(attrs, effect_context, opts)
      when is_map(attrs) and is_map(effect_context) and is_list(opts) do
    with :ok <- validate_context_binding(attrs, effect_context) do
      bound_attrs = bind_objective_context(attrs, effect_context)

      Store.create(
        bound_attrs,
        effect_context,
        binding_opts(opts, objective_binding_kind(bound_attrs, effect_context))
      )
    end
  end

  # The former opts-only internal API is routed through the generated default
  # arity and fails here because it cannot carry a valid readiness context.
  def create(_attrs, _effect_context, _opts), do: {:error, :product_not_ready}

  @doc """
  Create a confirmation bound to the objective/step in the carried runner
  context. The context must contain the exact ready E1 accepted by Pack
  Readiness; legacy opts-only calls fail closed.

  Objective provenance is copied into top-level record fields, the redacted
  origin, and the bounded rendering snapshot. The runner context wins over any
  action-supplied values so a confirmed fan-out step cannot redirect approval
  to another objective or step.
  """
  defdelegate read(id), to: Store
  defdelegate list(opts \\ []), to: Store
  defdelegate resolve(id, status, resolution_attrs, effect_context, opts \\ []), to: Store
  defdelegate annotate_resolution(id, attrs, effect_context, opts \\ []), to: Store
  defdelegate expire(effect_context, opts \\ []), to: Store

  @doc false
  @spec bind_objective_context(map(), map()) :: map()
  def bind_objective_context(attrs, context) when is_map(attrs) and is_map(context) do
    objective_id = Maps.field(context, :objective_id)
    step_id = Maps.field(context, :step_id)

    attrs
    |> put_context_value(:objective_id, objective_id)
    |> put_context_value(:step_id, step_id)
    |> bind_target_action(context)
    |> update_context_map(:origin, objective_context_snapshot(context))
    |> update_context_map(:params_summary, objective_rendering_snapshot(context))
  end

  @doc """
  Redact confirmation internals before returning records through operator-facing
  action responses.

  Approval uses the stored record directly. This helper is for list/show/approve
  output where resumable voice payloads must not expose local audio paths or the
  full text being synthesized.
  """
  @spec redact_for_output(map()) :: map()
  def redact_for_output(%{} = record) do
    case get_in(record, ["target_action", "name"]) do
      "transcribe_voice" ->
        redact_resume_params(record, %{
          "audio_file" => "[REDACTED_AUDIO_PATH]",
          "file" => "[REDACTED_AUDIO_PATH]",
          "path" => "[REDACTED_AUDIO_PATH]",
          "resource_uri" =>
            Redactor.redact_audio_resource_uri(
              get_in(record, ["resume_params_ref", "resource_uri"])
            )
        })

      "synthesize_voice" ->
        redact_resume_params(record, %{
          "text" => "[REDACTED]",
          "input" => "[REDACTED]",
          "prompt" => "[REDACTED]",
          "output_format" => get_in(record, ["resume_params_ref", "output_format"]),
          "voice" => get_in(record, ["resume_params_ref", "voice"])
        })

      "write" ->
        redact_resume_params(record, %{
          "action" => "write",
          "path" => get_in(record, ["resume_params_ref", "path"]),
          "content" => "[REDACTED]",
          "max_bytes" => get_in(record, ["resume_params_ref", "max_bytes"]),
          "content_sha256" => get_in(record, ["resume_params_ref", "content_sha256"])
        })

      "edit" ->
        redact_resume_params(record, %{
          "action" => "edit",
          "path" => get_in(record, ["resume_params_ref", "path"]),
          "old_text" => "[REDACTED]",
          "new_text" => "[REDACTED]",
          "max_bytes" => get_in(record, ["resume_params_ref", "max_bytes"]),
          "max_replacements" => get_in(record, ["resume_params_ref", "max_replacements"]),
          "old_text_sha256" => get_in(record, ["resume_params_ref", "old_text_sha256"]),
          "new_text_sha256" => get_in(record, ["resume_params_ref", "new_text_sha256"])
        })

      "bash" ->
        redact_resume_params(record, %{
          "action" => "bash",
          "mode" => get_in(record, ["resume_params_ref", "mode"]),
          "executable" => get_in(record, ["resume_params_ref", "executable"]),
          "args" => "[REDACTED_ARGS]",
          "command" => "[REDACTED_COMMAND]",
          "cwd" => get_in(record, ["resume_params_ref", "cwd"]),
          "timeout_ms" => get_in(record, ["resume_params_ref", "timeout_ms"]),
          "max_output_bytes" => get_in(record, ["resume_params_ref", "max_output_bytes"]),
          "env" => "[REDACTED_ENV]"
        })

      _other ->
        record
    end
  end

  def redact_for_output(record), do: record

  @doc "Return the operator-facing explanation for adapter-unavailable approvals."
  @spec adapter_unavailable_note() :: String.t()
  def adapter_unavailable_note, do: @adapter_unavailable_note

  @doc "Return a human-readable status note for confirmation records that need one."
  @spec status_note(map()) :: String.t() | nil
  def status_note(%{"status" => "adapter_unavailable"}), do: @adapter_unavailable_note
  def status_note(_record), do: nil

  @doc "Return the standard operator-facing confirmation resolution message."
  @spec status_message(map()) :: String.t()
  def status_message(record) when is_map(record) do
    message = "Confirmation #{record["id"]} is #{record["status"]}."

    case status_note(record) do
      nil -> message
      note -> "#{message} #{note}"
    end
  end

  defp redact_resume_params(record, replacement) do
    Map.put(
      record,
      "resume_params_ref",
      replacement
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    )
  end

  defp put_context_value(attrs, _key, value) when value in [nil, ""], do: attrs
  defp put_context_value(attrs, key, value), do: Map.put(attrs, key, value)

  defp update_context_map(attrs, _key, additions) when additions == %{}, do: attrs

  defp update_context_map(attrs, key, additions) do
    current = Maps.field(attrs, key, %{})
    current = if is_map(current), do: current, else: %{}
    Map.put(attrs, key, Map.merge(current, additions))
  end

  defp objective_context_snapshot(context) do
    %{
      user_id: Maps.field(context, :user_id),
      objective_id: Maps.field(context, :objective_id),
      step_id: Maps.field(context, :step_id),
      parent_objective_id: Maps.field(context, :parent_objective_id)
    }
    |> reject_blank_values()
  end

  defp objective_rendering_snapshot(context) do
    %{
      execution_objective_id: Maps.field(context, :objective_id),
      execution_step_id: Maps.field(context, :step_id),
      objective_title: Maps.field(context, :objective_title),
      objective_status: Maps.field(context, :objective_status)
    }
    |> reject_blank_values()
  end

  defp reject_blank_values(map) do
    Map.reject(map, fn {_key, value} -> value in [nil, ""] end)
  end

  defp validate_context_binding(attrs, context) do
    with :ok <- validate_objective_binding_shape(context),
         :ok <- validate_matching_value(attrs, context, :objective_id),
         :ok <- validate_matching_value(attrs, context, :step_id),
         :ok <- validate_target_action(attrs, context),
         :ok <- validate_resume_params(attrs, context) do
      :ok
    end
  end

  defp validate_matching_value(attrs, context, field) do
    existing = Maps.field(attrs, field)
    trusted = Maps.field(context, field)

    if present?(existing) and present?(trusted) and to_string(existing) != to_string(trusted) do
      {:error, {:confirmation_binding_mismatch, field}}
    else
      :ok
    end
  end

  defp validate_target_action(attrs, context) do
    target = Maps.field(attrs, :target_action, %{})
    existing_name = if is_map(target), do: Maps.field(target, :name), else: target
    existing_module = if is_map(target), do: Maps.field(target, :module), else: nil
    trusted_name = Maps.field(context, :selected_action)
    trusted_module = Maps.field(context, :selected_action_module)
    trusted_module_name = trusted_module_name(trusted_module)

    cond do
      present?(trusted_name) and to_string(existing_name) != to_string(trusted_name) ->
        {:error, {:confirmation_binding_mismatch, :target_action}}

      present?(existing_module) and present?(trusted_module_name) and
          to_string(existing_module) != trusted_module_name ->
        {:error, {:confirmation_binding_mismatch, :target_action_module}}

      true ->
        :ok
    end
  end

  defp validate_resume_params(attrs, context) do
    if present?(Maps.field(context, :selected_action)) and
         not is_map(Maps.field(attrs, :resume_params_ref)) do
      {:error, {:invalid_confirmation_binding, :resume_params_ref}}
    else
      :ok
    end
  end

  defp bind_target_action(attrs, context) do
    trusted_name = Maps.field(context, :selected_action)
    trusted_module = Maps.field(context, :selected_action_module)

    additions =
      %{
        name: trusted_name,
        module: trusted_module_name(trusted_module)
      }
      |> reject_blank_values()

    update_context_map(attrs, :target_action, additions)
  end

  defp present?(value), do: value not in [nil, ""]

  defp objective_binding_kind(attrs, context) do
    cond do
      present?(Maps.field(context, :parent_objective_id)) ->
        :fanout_child

      present?(Maps.field(attrs, :objective_id)) and present?(Maps.field(attrs, :step_id)) ->
        :objective

      true ->
        :ordinary
    end
  end

  defp validate_objective_binding_shape(context) do
    objective? = present?(Maps.field(context, :objective_id))
    step? = present?(Maps.field(context, :step_id))
    parent? = present?(Maps.field(context, :parent_objective_id))

    cond do
      parent? and not (objective? and step?) ->
        {:error, {:invalid_confirmation_binding, :fanout_provenance}}

      parent? and not present?(Maps.field(context, :user_id)) ->
        {:error, {:invalid_confirmation_binding, :fanout_owner}}

      step? and not objective? ->
        {:error, {:invalid_confirmation_binding, :objective_provenance}}

      true ->
        :ok
    end
  end

  defp binding_opts(opts, kind), do: Keyword.put(opts, :objective_binding_kind, kind)

  defp trusted_module_name(module) when is_atom(module) and module != nil,
    do: inspect(module)

  defp trusted_module_name(_module), do: nil
end
