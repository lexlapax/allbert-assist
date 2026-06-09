defmodule AllbertAssist.PublicProtocol.ResultReadback do
  @moduledoc """
  Public protocol poll-by-id result readback.

  External clients receive a public call id for confirmation-gated work. This
  context keeps the per-client ownership row and returns only client-scoped,
  redacted readback views.
  """

  import Ecto.Query

  alias AllbertAssist.Confirmations
  alias AllbertAssist.PublicProtocol.CallResult
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings

  @pending "pending"
  @approved "approved_with_result"
  @denied "denied"
  @expired "expired"

  @type caller :: %{surface: String.t(), client_id: String.t()}
  @type readback_view :: %{
          required(:id) => String.t(),
          required(:status) => atom(),
          optional(:result) => map(),
          optional(:error) => map()
        }

  @doc "Generate an opaque public call id."
  @spec new_id() :: String.t()
  def new_id, do: "pubcall_" <> Ecto.UUID.generate()

  @doc "Create a pending client-owned readback row."
  @spec create(map(), keyword()) :: {:ok, CallResult.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    ttl_ms = Keyword.get(opts, :ttl_ms, default_ttl_ms())
    expires_at = Map.get(attrs, :expires_at) || Map.get(attrs, "expires_at")

    attrs =
      attrs
      |> atomize_known()
      |> Map.put_new(:id, new_id())
      |> Map.put_new(:status, @pending)
      |> Map.put_new(:result, %{})
      |> Map.put_new(:error, %{})
      |> Map.put_new(:trace_metadata, %{})
      |> Map.put(:expires_at, expires_at || DateTime.add(now, ttl_ms, :millisecond))
      |> redact_attrs()

    %CallResult{}
    |> CallResult.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Return a client-scoped readback view for a public call id."
  @spec get_for_client(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, readback_view()} | {:error, term()}
  def get_for_client(id, surface, client_id, opts \\ [])
      when is_binary(id) and is_binary(surface) and is_binary(client_id) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with %CallResult{} = call_result <- Repo.get(CallResult, id),
         :ok <- authorize(call_result, surface, client_id),
         {:ok, call_result} <- ensure_current(call_result, now) do
      {:ok, to_view(call_result)}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Extract public protocol caller scope from a runner/action context."
  @spec caller_from_context(map()) :: {:ok, caller()} | {:error, term()}
  def caller_from_context(context) when is_map(context) do
    public_protocol =
      Map.get(context, :public_protocol) || Map.get(context, "public_protocol") || %{}

    surface =
      Map.get(public_protocol, :surface) ||
        Map.get(public_protocol, "surface") ||
        Map.get(context, :surface) ||
        Map.get(context, "surface")

    client_id =
      Map.get(public_protocol, :client_id) ||
        Map.get(public_protocol, "client_id") ||
        Map.get(context, :client_id) ||
        Map.get(context, "client_id")

    with {:ok, surface} <- validate_surface(surface),
         {:ok, client_id} <- validate_client_id(client_id) do
      {:ok, %{surface: surface, client_id: client_id}}
    end
  end

  def caller_from_context(_context), do: {:error, :missing_public_protocol_context}

  @doc "Synchronize matching readback rows from a resolved confirmation record."
  @spec sync_confirmation(map(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sync_confirmation(record, opts \\ [])

  def sync_confirmation(%{"id" => confirmation_id} = record, opts)
      when is_binary(confirmation_id) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case attrs_from_confirmation(record, now) do
      {:ok, attrs} ->
        count =
          CallResult
          |> where([call], call.confirmation_id == ^confirmation_id)
          |> where([call], call.status != ^@expired)
          |> Repo.all()
          |> Enum.reduce(0, fn call_result, count ->
            case update_call_result(call_result, attrs) do
              {:ok, _updated} -> count + 1
              {:error, _changeset} -> count
            end
          end)

        {:ok, count}

      :pending ->
        {:ok, 0}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def sync_confirmation(_record, _opts), do: {:error, :invalid_confirmation_record}

  @doc "Expire all non-expired rows whose readback TTL has elapsed."
  @spec sweep_expired(keyword()) :: {:ok, non_neg_integer()}
  def sweep_expired(opts \\ []) when is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    {count, _rows} =
      CallResult
      |> where([call], call.status != ^@expired)
      |> where([call], call.expires_at <= ^now)
      |> Repo.update_all(
        set: [
          status: @expired,
          result: %{},
          error: %{},
          expired_at: now,
          updated_at: now
        ]
      )

    {:ok, count}
  end

  defp ensure_current(%CallResult{} = call_result, now) do
    cond do
      expired?(call_result, now) ->
        expire_call_result(call_result, now)

      call_result.status == @pending ->
        refresh_pending_confirmation(call_result, now)

      true ->
        {:ok, call_result}
    end
  end

  defp refresh_pending_confirmation(%CallResult{confirmation_id: nil} = call_result, _now),
    do: {:ok, call_result}

  defp refresh_pending_confirmation(%CallResult{confirmation_id: ""} = call_result, _now),
    do: {:ok, call_result}

  defp refresh_pending_confirmation(
         %CallResult{confirmation_id: confirmation_id} = call_result,
         now
       ) do
    case Confirmations.read(confirmation_id) do
      {:ok, %{"status" => "pending"}} ->
        {:ok, call_result}

      {:ok, record} ->
        with {:ok, _count} <- sync_confirmation(record, now: now) do
          {:ok, Repo.get(CallResult, call_result.id) || call_result}
        end

      {:error, _reason} ->
        {:ok, call_result}
    end
  end

  defp authorize(%CallResult{surface: surface, client_id: client_id}, surface, client_id), do: :ok
  defp authorize(_call_result, _surface, _client_id), do: {:error, :not_authorized}

  defp expired?(%CallResult{expires_at: expires_at}, now) do
    DateTime.compare(expires_at, now) in [:lt, :eq]
  end

  defp expire_call_result(%CallResult{status: @expired} = call_result, _now),
    do: {:ok, call_result}

  defp expire_call_result(%CallResult{} = call_result, now) do
    update_call_result(call_result, %{
      status: @expired,
      result: %{},
      error: %{},
      expired_at: now
    })
  end

  defp attrs_from_confirmation(%{"status" => "pending"}, _now), do: :pending

  defp attrs_from_confirmation(%{"status" => "approved"} = record, now) do
    {:ok,
     %{
       status: @approved,
       result: result_from_confirmation(record),
       error: %{},
       resolved_at: resolved_at(record, now)
     }}
  end

  defp attrs_from_confirmation(%{"status" => "expired"} = record, now) do
    {:ok,
     %{
       status: @expired,
       result: %{},
       error: %{},
       resolved_at: resolved_at(record, now),
       expired_at: resolved_at(record, now)
     }}
  end

  defp attrs_from_confirmation(%{"status" => status} = record, now)
       when status in ["denied", "cancelled", "adapter_unavailable"] do
    {:ok,
     %{
       status: @denied,
       result: %{},
       error: error_from_confirmation(record),
       resolved_at: resolved_at(record, now)
     }}
  end

  defp attrs_from_confirmation(%{"status" => status}, _now),
    do: {:error, {:unknown_status, status}}

  defp result_from_confirmation(record) do
    record
    |> get_in(["operator_resolution", "target_result"])
    |> case do
      result when is_map(result) -> result
      _other -> %{"status" => "approved"}
    end
    |> Redactor.redact()
  end

  defp error_from_confirmation(record) do
    %{
      status: Map.get(record, "status"),
      reason: get_in(record, ["operator_resolution", "resolution_reason"]),
      target_status: get_in(record, ["operator_resolution", "target_status"])
    }
    |> drop_nil_values()
    |> Redactor.redact()
  end

  defp resolved_at(record, fallback) do
    parse_datetime(Map.get(record, "resolved_at")) ||
      parse_datetime(get_in(record, ["operator_resolution", "resolved_at"])) ||
      fallback
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp update_call_result(%CallResult{} = call_result, attrs) do
    call_result
    |> CallResult.changeset(redact_attrs(attrs))
    |> Repo.update()
  end

  defp to_view(%CallResult{status: @approved} = call_result) do
    base_view(call_result)
    |> Map.put(:status, :approved_with_result)
    |> Map.put(:result, call_result.result || %{})
  end

  defp to_view(%CallResult{status: @denied} = call_result) do
    base_view(call_result)
    |> Map.put(:status, :denied)
    |> Map.put(:error, call_result.error || %{})
  end

  defp to_view(%CallResult{status: @expired} = call_result) do
    base_view(call_result)
    |> Map.put(:status, :expired)
  end

  defp to_view(%CallResult{} = call_result) do
    base_view(call_result)
    |> Map.put(:status, :pending)
  end

  defp base_view(call_result) do
    %{
      id: call_result.id,
      surface: call_result.surface,
      action_label: call_result.action_label,
      turn_label: call_result.turn_label,
      trace_id: call_result.trace_id,
      expires_at: call_result.expires_at,
      resolved_at: call_result.resolved_at
    }
    |> drop_nil_values()
  end

  defp redact_attrs(attrs) do
    attrs
    |> Map.update(:result, %{}, &redacted_map/1)
    |> Map.update(:error, %{}, &redacted_map/1)
    |> Map.update(:trace_metadata, %{}, &redacted_map/1)
  end

  defp redacted_map(value) when is_map(value), do: value |> stringify_keys() |> Redactor.redact()
  defp redacted_map(_value), do: %{}

  defp atomize_known(attrs) do
    known = ~w[
      id surface client_id action_label turn_label confirmation_id trace_id status result error
      trace_metadata resolved_at expires_at expired_at
    ]a

    Enum.reduce(known, attrs, fn key, acc ->
      string_key = Atom.to_string(key)

      if Map.has_key?(acc, string_key) do
        acc |> Map.put(key, Map.fetch!(acc, string_key)) |> Map.delete(string_key)
      else
        acc
      end
    end)
  end

  defp stringify_keys(%{} = map) do
    Map.new(map, fn
      {key, value} when is_map(value) -> {to_string(key), stringify_keys(value)}
      {key, value} when is_list(value) -> {to_string(key), Enum.map(value, &stringify_value/1)}
      {key, value} -> {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_value(%{} = value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value

  defp validate_surface(value) when is_atom(value), do: validate_surface(Atom.to_string(value))

  defp validate_surface(value) when is_binary(value) do
    if value in CallResult.surfaces() do
      {:ok, value}
    else
      {:error, {:invalid_public_protocol_surface, value}}
    end
  end

  defp validate_surface(_value), do: {:error, :missing_public_protocol_surface}

  defp validate_client_id(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      {:error, :missing_public_protocol_client_id}
    else
      {:ok, value}
    end
  end

  defp validate_client_id(_value), do: {:error, :missing_public_protocol_client_id}

  defp default_ttl_ms do
    case Settings.get("public_protocol.result_readback_ttl_ms") do
      {:ok, ttl_ms} when is_integer(ttl_ms) -> ttl_ms
      _other -> 3_600_000
    end
  end

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
