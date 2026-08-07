defmodule AllbertAssist.Channels.TUI.InputReceipt do
  @moduledoc """
  Durable, non-process admission gate for daemon-owned TUI input receipts.

  Receipt rows extend the existing channel-event dedupe seam. This module
  normalizes and binds input before dispatch; it owns no session, process, or
  runtime authority.
  """

  import Ecto.Query, only: [from: 2]

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime.Attach.TUIProtocol
  alias AllbertAssist.Settings.KeyCustody

  @channel "tui"
  @provider "terminal"
  @normalizer_version "tui-input-v1"
  @hmac_domain "allbert.tui.receipt-payload.v1"
  @integrity_ref "secret://system/integrity_v1"
  @integrity_version 1
  @admission_ref_keys [:input_signal_id, :thread_id, :trace_id]
  @terminal_ref_keys [
    :input_signal_id,
    :thread_id,
    :trace_id,
    :receipt_message_id,
    :receipt_result_ref
  ]

  @type duplicate_owner :: :live | :orphaned
  @type gate_result ::
          %{
            required(:disposition) => :dispatch | :duplicate,
            required(:event) => AllbertAssist.Channels.Event.t(),
            optional(:normalized_text) => String.t(),
            optional(:state) => atom() | nil,
            optional(:outcome) => atom() | nil,
            optional(:message_id) => String.t() | nil,
            optional(:result_ref) => String.t() | nil
          }

  @spec gate(map(), keyword()) ::
          {:ok, gate_result()}
          | {:error,
             :invalid_input
             | :invalid_receipt
             | :invalid_identity
             | :receipt_conflict
             | :receipt_key_unavailable
             | Ecto.Changeset.t()}
  def gate(attrs, opts) when is_map(attrs) and is_list(opts) do
    with {:ok, duplicate_owner} <- duplicate_owner(opts),
         {:ok, operator_id} <- bounded_identity(Map.get(attrs, :verified_operator_id)),
         {:ok, profile} <- TUIProtocol.normalize_profile(Map.get(attrs, :profile)),
         :ok <- validate_receipt_id(Map.get(attrs, :input_receipt_id)),
         {:ok, normalized_text} <-
           TUIProtocol.normalize_input(
             Map.get(attrs, :text),
             Map.get(attrs, :max_text_bytes)
           ) do
      receipt_id = Map.fetch!(attrs, :input_receipt_id)
      external_event_id = external_event_id(operator_id, profile, receipt_id)

      gate_transaction(%{
        duplicate_owner: duplicate_owner,
        external_event_id: external_event_id,
        normalized_text: normalized_text,
        operator_id: operator_id,
        profile: profile,
        receipt_id: receipt_id,
        session_id: Map.get(attrs, :session_id),
        allbert_pack_epoch: Map.get(attrs, :allbert_pack_epoch)
      })
    else
      {:error, :invalid_profile} -> {:error, :invalid_identity}
      {:error, reason} -> {:error, reason}
    end
  end

  def gate(_attrs, _opts), do: {:error, :invalid_input}

  @spec mark_admitted(Event.t(), map()) ::
          {:ok, Event.t()} | {:error, Ecto.Changeset.t() | atom()}
  def mark_admitted(%Event{} = event, safe_refs) when is_map(safe_refs) do
    mark_admitted(event, safe_refs, %{})
  end

  def mark_admitted(_event, _safe_refs), do: {:error, :invalid_receipt_transition}

  def mark_admitted(%Event{} = event, safe_refs, context)
      when is_map(safe_refs) and is_map(context) do
    with {:ok, refs} <- safe_refs(safe_refs, @admission_ref_keys) do
      transition(event, context, &admit_transition(&1, refs, context))
    end
  end

  @spec mark_in_progress(Event.t()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t() | atom()}
  def mark_in_progress(%Event{} = event) do
    mark_in_progress(event, %{})
  end

  def mark_in_progress(_event), do: {:error, :invalid_receipt_transition}

  def mark_in_progress(%Event{} = event, context) when is_map(context) do
    transition(event, context, fn current ->
      case current.receipt_state do
        "admitted" -> Channels.update_event(current, %{receipt_state: "in_progress"}, context)
        "in_progress" -> {:ok, current}
        _other -> {:error, :invalid_receipt_transition}
      end
    end)
  end

  @spec mark_terminal(Event.t(), :completed | :rejected | :failed, map()) ::
          {:ok, Event.t()} | {:error, Ecto.Changeset.t() | atom()}
  def mark_terminal(%Event{} = event, outcome, safe_refs)
      when outcome in [:completed, :rejected, :failed] and is_map(safe_refs) do
    mark_terminal(event, outcome, safe_refs, %{})
  end

  def mark_terminal(_event, _outcome, _safe_refs),
    do: {:error, :invalid_receipt_transition}

  def mark_terminal(%Event{} = event, outcome, safe_refs, context)
      when outcome in [:completed, :rejected, :failed] and is_map(safe_refs) and is_map(context) do
    with {:ok, refs} <- safe_refs(safe_refs, @terminal_ref_keys) do
      transition(event, context, &terminal_transition(&1, outcome, refs, context))
    end
  end

  defp gate_transaction(context) do
    case Repo.transaction(fn -> insert_or_load(context) end, mode: :immediate) do
      {:ok, result} -> result
      {:error, _reason} -> {:error, :receipt_key_unavailable}
    end
  end

  defp transition(%Event{} = event, context, fun) when is_map(context) and is_function(fun, 1) do
    case Repo.transaction(fn -> apply_transition(event, fun) end, mode: :immediate) do
      {:ok, result} -> result
      {:error, _reason} -> {:error, :invalid_receipt_transition}
    end
  end

  defp apply_transition(event, fun) do
    case Repo.get(Event, event.id) do
      %Event{external_event_id: external_event_id} = current
      when external_event_id == event.external_event_id ->
        apply_receipt_transition(current, fun)

      _other ->
        {:error, :invalid_receipt_transition}
    end
  end

  defp apply_receipt_transition(current, fun) do
    with true <- receipt_event?(current),
         :ok <- validate_receipt_state(current) do
      fun.(current)
    else
      _invalid -> {:error, :invalid_receipt_transition}
    end
  end

  defp admit_transition(%Event{receipt_state: "received"} = current, refs, context) do
    with {:ok, reconciled_refs} <- reconcile_refs(current, refs) do
      Channels.update_event(
        current,
        Map.put(reconciled_refs, :receipt_state, "admitted"),
        context
      )
    end
  end

  defp admit_transition(%Event{receipt_state: "admitted"} = current, refs, _context) do
    if refs_match?(current, refs),
      do: {:ok, current},
      else: {:error, :invalid_receipt_transition}
  end

  defp admit_transition(_current, _refs, _context), do: {:error, :invalid_receipt_transition}

  defp terminal_transition(%Event{receipt_state: state} = current, outcome, refs, context)
       when state in ["admitted", "in_progress"] do
    with {:ok, canonical_outcome} <- canonical_terminal_outcome(current.status, outcome),
         {:ok, reconciled_refs} <- reconcile_refs(current, refs) do
      terminal_state = Atom.to_string(canonical_outcome)

      attrs =
        reconciled_refs
        |> Map.merge(%{
          receipt_state: terminal_state,
          receipt_outcome: terminal_state,
          status: terminal_status(canonical_outcome)
        })

      Channels.update_event(current, attrs, context)
    end
  end

  defp terminal_transition(%Event{} = current, outcome, refs, _context) do
    with {:ok, canonical_outcome} <- canonical_terminal_outcome(current.status, outcome) do
      terminal_state = Atom.to_string(canonical_outcome)

      if current.receipt_state == terminal_state and
           current.receipt_outcome == terminal_state and
           current.status == terminal_status(canonical_outcome) and refs_match?(current, refs),
         do: {:ok, current},
         else: {:error, :invalid_receipt_transition}
    end
  end

  defp insert_or_load(context) do
    case Channels.get_event_by_external_id(@channel, context.external_event_id) do
      nil -> insert_receipt(context)
      event -> duplicate_receipt(event, context)
    end
  end

  defp insert_receipt(context) do
    with :ok <- ensure_referenced_key_available(),
         {:ok, hmac} <- payload_hmac(context.normalized_text) do
      do_insert_receipt(context, hmac)
    end
  end

  defp ensure_referenced_key_available do
    probe =
      Repo.one(
        from(event in Event,
          where:
            event.channel == @channel and
              event.direction == "inbound" and
              event.receipt_hmac_key_ref == @integrity_ref and
              event.receipt_hmac_key_version == @integrity_version,
          order_by: [asc: event.id],
          limit: 1
        )
      )

    case probe do
      nil ->
        :ok

      %Event{} = event ->
        with {:ok, tag} <- decode_tag(event.receipt_payload_hmac),
             {:ok, _matches?} <-
               KeyCustody.verify_system_hmac(
                 @hmac_domain,
                 [@normalizer_version, "integrity-key-availability-probe-v1"],
                 tag,
                 event.receipt_hmac_key_ref,
                 event.receipt_hmac_key_version
               ) do
          :ok
        else
          _other -> {:error, :receipt_key_unavailable}
        end
    end
  end

  defp do_insert_receipt(context, hmac) do
    attrs = %{
      channel: @channel,
      provider: @provider,
      direction: "inbound",
      external_event_id: context.external_event_id,
      external_user_id: context.profile,
      external_chat_id: "tui:" <> context.profile,
      external_message_id: context.receipt_id,
      user_id: context.operator_id,
      session_id: context.session_id,
      status: "received",
      receipt_normalizer_version: @normalizer_version,
      receipt_hmac_key_ref: hmac.key_ref,
      receipt_hmac_key_version: hmac.key_version,
      receipt_payload_hmac: hmac.encoded_tag,
      receipt_state: "received"
    }

    case Channels.create_event(attrs, %{allbert_pack_epoch: Map.get(context, :allbert_pack_epoch)}) do
      {:ok, event} ->
        {:ok, %{disposition: :dispatch, event: event, normalized_text: context.normalized_text}}

      {:error, changeset} ->
        case Channels.get_event_by_external_id(@channel, context.external_event_id) do
          nil -> {:error, changeset}
          event -> duplicate_receipt(event, context)
        end
    end
  end

  defp duplicate_receipt(event, context) do
    with :ok <- validate_receipt_event(event),
         {:ok, tag} <- decode_tag(event.receipt_payload_hmac),
         {:ok, true} <-
           KeyCustody.verify_system_hmac(
             @hmac_domain,
             [@normalizer_version, context.normalized_text],
             tag,
             event.receipt_hmac_key_ref,
             event.receipt_hmac_key_version
           ),
         {:ok, current} <- reload_verified_receipt(event),
         :ok <- validate_receipt_state(current) do
      reconcile_duplicate(current, context.duplicate_owner, %{
        allbert_pack_epoch: context.allbert_pack_epoch
      })
    else
      {:ok, false} -> {:error, :receipt_conflict}
      {:error, :receipt_conflict} = error -> error
      _other -> {:error, :receipt_key_unavailable}
    end
  end

  defp reconcile_duplicate(
         %Event{receipt_state: state} = event,
         :orphaned,
         context
       )
       when state in ["received", "admitted", "in_progress"] do
    case durable_terminal_outcome(event.status) do
      {:ok, outcome} -> reconcile_terminal_duplicate(event, outcome, context)
      :nonterminal -> reconcile_unknown_duplicate(event, context)
      :invalid -> {:error, :receipt_conflict}
    end
  end

  defp reconcile_duplicate(%Event{} = event, _duplicate_owner, _context),
    do: {:ok, duplicate_result(event)}

  defp reconcile_terminal_duplicate(event, outcome, context) do
    terminal_state = Atom.to_string(outcome)

    case Channels.update_event(
           event,
           %{
             receipt_state: terminal_state,
             receipt_outcome: terminal_state,
             status: terminal_status(outcome)
           },
           context
         ) do
      {:ok, terminal} -> {:ok, duplicate_result(terminal)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp reconcile_unknown_duplicate(event, context) do
    case Channels.update_event(
           event,
           %{
             receipt_state: "outcome_unknown",
             receipt_outcome: "outcome_unknown",
             status: "failed"
           },
           context
         ) do
      {:ok, unknown} -> {:ok, duplicate_result(unknown)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp duplicate_result(event) do
    %{
      disposition: :duplicate,
      event: event,
      state: receipt_state(event.receipt_state),
      outcome: receipt_outcome(event.receipt_outcome),
      message_id: event.receipt_message_id,
      result_ref: event.receipt_result_ref
    }
  end

  defp decode_tag(encoded) when is_binary(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, tag} when byte_size(tag) == 32 -> {:ok, tag}
      _other -> {:error, :invalid_tag}
    end
  end

  defp decode_tag(_encoded), do: {:error, :invalid_tag}

  defp receipt_state("received"), do: :received
  defp receipt_state("admitted"), do: :admitted
  defp receipt_state("in_progress"), do: :in_progress
  defp receipt_state("completed"), do: :completed
  defp receipt_state("rejected"), do: :rejected
  defp receipt_state("failed"), do: :failed
  defp receipt_state("outcome_unknown"), do: :outcome_unknown
  defp receipt_state(_state), do: nil

  defp receipt_outcome("completed"), do: :completed
  defp receipt_outcome("rejected"), do: :rejected
  defp receipt_outcome("failed"), do: :failed
  defp receipt_outcome("outcome_unknown"), do: :outcome_unknown
  defp receipt_outcome(_outcome), do: nil

  defp receipt_event?(%Event{
         channel: @channel,
         provider: @provider,
         direction: "inbound",
         receipt_normalizer_version: @normalizer_version,
         receipt_hmac_key_ref: @integrity_ref,
         receipt_hmac_key_version: @integrity_version
       }),
       do: true

  defp receipt_event?(_event), do: false

  defp refs_match?(event, refs) do
    Enum.all?(refs, fn {key, value} -> Map.fetch!(event, key) == value end)
  end

  defp reconcile_refs(event, refs) do
    Enum.reduce_while(refs, {:ok, %{}}, fn {key, requested}, {:ok, acc} ->
      case Map.fetch!(event, key) do
        nil -> {:cont, {:ok, Map.put(acc, key, requested)}}
        existing when is_nil(requested) or requested == existing -> {:cont, {:ok, acc}}
        _conflict -> {:halt, {:error, :invalid_receipt_transition}}
      end
    end)
  end

  defp validate_receipt_event(event) do
    if receipt_event?(event), do: :ok, else: {:error, :receipt_conflict}
  end

  defp reload_verified_receipt(event) do
    case Repo.get(Event, event.id) do
      %Event{} = current ->
        if receipt_binding(current) == receipt_binding(event) and receipt_event?(current),
          do: {:ok, current},
          else: {:error, :receipt_conflict}

      nil ->
        {:error, :receipt_conflict}
    end
  end

  defp receipt_binding(event) do
    {
      event.channel,
      event.provider,
      event.direction,
      event.external_event_id,
      event.external_user_id,
      event.external_chat_id,
      event.external_message_id,
      event.receipt_normalizer_version,
      event.receipt_hmac_key_ref,
      event.receipt_hmac_key_version,
      event.receipt_payload_hmac
    }
  end

  defp validate_receipt_state(%Event{
         receipt_state: state,
         receipt_outcome: nil,
         status: status
       })
       when state in ["received", "admitted", "in_progress"] and
              status in ["received", "processed", "rejected", "failed"],
       do: :ok

  defp validate_receipt_state(%Event{
         receipt_state: "completed",
         receipt_outcome: "completed",
         status: "processed"
       }),
       do: :ok

  defp validate_receipt_state(%Event{
         receipt_state: "rejected",
         receipt_outcome: "rejected",
         status: "rejected"
       }),
       do: :ok

  defp validate_receipt_state(%Event{
         receipt_state: "failed",
         receipt_outcome: "failed",
         status: "failed"
       }),
       do: :ok

  defp validate_receipt_state(%Event{
         receipt_state: "outcome_unknown",
         receipt_outcome: "outcome_unknown",
         status: "failed"
       }),
       do: :ok

  defp validate_receipt_state(_event), do: {:error, :receipt_conflict}

  defp safe_refs(refs, allowed_keys) do
    if Enum.all?(Map.keys(refs), &(&1 in allowed_keys)) do
      reduce_safe_refs(refs)
    else
      {:error, :invalid_receipt_refs}
    end
  end

  defp reduce_safe_refs(refs) do
    Enum.reduce_while(refs, {:ok, %{}}, &put_safe_ref/2)
  end

  defp put_safe_ref({key, value}, {:ok, acc}) do
    case safe_ref(key, value) do
      {:ok, safe_value} -> {:cont, {:ok, Map.put(acc, key, safe_value)}}
      :error -> {:halt, {:error, :invalid_receipt_refs}}
    end
  end

  defp safe_ref(_key, nil), do: {:ok, nil}

  defp safe_ref(key, value) when is_binary(value) do
    maximum =
      case key do
        :trace_id -> 500
        :receipt_result_ref -> 256
        _other -> 128
      end

    if String.valid?(value) and byte_size(value) in 1..maximum,
      do: {:ok, value},
      else: :error
  end

  defp safe_ref(_key, _value), do: :error

  defp terminal_status(:completed), do: "processed"
  defp terminal_status(:rejected), do: "rejected"
  defp terminal_status(:failed), do: "failed"

  defp canonical_terminal_outcome("received", requested), do: {:ok, requested}

  defp canonical_terminal_outcome(status, _requested) do
    case durable_terminal_outcome(status) do
      {:ok, outcome} -> {:ok, outcome}
      _other -> {:error, :invalid_receipt_transition}
    end
  end

  defp durable_terminal_outcome("processed"), do: {:ok, :completed}
  defp durable_terminal_outcome("rejected"), do: {:ok, :rejected}
  defp durable_terminal_outcome("failed"), do: {:ok, :failed}
  defp durable_terminal_outcome("received"), do: :nonterminal
  defp durable_terminal_outcome(_status), do: :invalid

  defp payload_hmac(normalized_text) do
    case KeyCustody.system_hmac(
           @hmac_domain,
           [@normalizer_version, normalized_text],
           @integrity_version
         ) do
      {:ok,
       %{
         tag: tag,
         key_ref: @integrity_ref,
         key_version: @integrity_version
       }}
      when is_binary(tag) and byte_size(tag) == 32 ->
        {:ok,
         %{
           encoded_tag: Base.url_encode64(tag, padding: false),
           key_ref: @integrity_ref,
           key_version: @integrity_version
         }}

      _other ->
        {:error, :receipt_key_unavailable}
    end
  end

  defp external_event_id(operator_id, profile, receipt_id) do
    digest =
      [@channel, operator_id, profile, receipt_id]
      |> encode_fields()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    "tui:r1:" <> digest
  end

  defp encode_fields(fields) do
    Enum.map(fields, fn field -> [<<byte_size(field)::unsigned-big-64>>, field] end)
  end

  defp duplicate_owner(opts) do
    case Keyword.fetch(opts, :duplicate_owner) do
      {:ok, owner} when owner in [:live, :orphaned] -> {:ok, owner}
      _other -> {:error, :invalid_input}
    end
  end

  defp bounded_identity(value) when is_binary(value) do
    if String.valid?(value) and byte_size(value) in 1..128,
      do: {:ok, value},
      else: {:error, :invalid_identity}
  end

  defp bounded_identity(_value), do: {:error, :invalid_identity}

  defp validate_receipt_id(receipt_id)
       when is_binary(receipt_id) and byte_size(receipt_id) == 22 do
    case Base.url_decode64(receipt_id, padding: false) do
      {:ok, decoded} when byte_size(decoded) == 16 ->
        if Base.url_encode64(decoded, padding: false) == receipt_id,
          do: :ok,
          else: {:error, :invalid_receipt}

      _other ->
        {:error, :invalid_receipt}
    end
  end

  defp validate_receipt_id(_receipt_id), do: {:error, :invalid_receipt}
end
