defmodule AllbertAssist.FirstRun.Enablement do
  @moduledoc """
  Detection-to-enablement projection for zero-click first run.

  It projects the existing six model states, preserves raw explicit consent,
  selects local before hosted, and delegates the only write to Settings Store's
  atomic absent-subset primitive. Detection never provisions or probes hosted
  providers.
  """

  alias AllbertAssist.FirstRun.Disclosure
  alias AllbertAssist.FirstRun.UsableModel
  alias AllbertAssist.Settings.Schema
  alias AllbertAssist.Settings.Store

  @model_states [
    :local_ready,
    :runtime_missing,
    :runtime_unhealthy,
    :model_missing,
    :below_hardware_floor,
    :byok_ready
  ]

  @repair_states %{
    runtime_missing: :nothing_detected,
    runtime_unhealthy: :needs_model,
    model_missing: :needs_model,
    below_hardware_floor: :below_floor,
    byok_ready: :nothing_detected
  }

  @spec reconcile(atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile(model_state, opts \\ [])

  def reconcile(model_state, opts) when model_state in @model_states do
    with {:ok, settings, user_settings} <- resolved_settings(opts) do
      reconcile_settings(model_state, settings, user_settings, opts)
    end
  end

  def reconcile(model_state, _opts), do: {:error, {:unknown_first_model_state, model_state}}

  @doc "Run boot reconciliation only when Req's supervised transport is available."
  @spec reconcile_on_boot(atom(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:deferred, :req_not_started}
  def reconcile_on_boot(model_state, opts \\ []) do
    if req_started?(opts) do
      reconcile(model_state, opts)
    else
      {:deferred, :req_not_started}
    end
  rescue
    _exception -> {:deferred, :req_not_started}
  catch
    :exit, _reason -> {:deferred, :req_not_started}
  end

  defp reconcile_settings(model_state, settings, user_settings, opts) do
    case Schema.get_dotted(user_settings, "intent.direct_answer_model_enabled") do
      false -> result(:sticky_disabled, model_state, nil)
      true -> reconcile_enabled(model_state, settings, opts)
      nil -> reconcile_absent(model_state, settings, opts)
    end
  end

  defp reconcile_enabled(model_state, settings, opts) do
    case selection_for(model_state, settings, opts) do
      {:ok, selection} -> result(:auto_enabled, model_state, selection)
      {:error, :no_usable_model} -> result(:enabled_unavailable, model_state, nil)
    end
  end

  defp reconcile_absent(model_state, settings, opts) do
    case selection_for(model_state, settings, opts) do
      {:ok, selection} -> enable(model_state, selection, opts)
      {:error, :no_usable_model} -> result(repair_state(model_state), model_state, nil)
    end
  end

  defp selection_for(:local_ready, settings, opts), do: local_selection(settings, opts)

  defp selection_for(_unusable_or_missing, settings, opts),
    do: hosted_selection(settings, opts)

  defp local_selection(settings, opts) do
    case Keyword.fetch(opts, :local_selection) do
      {:ok, selection} -> normalize_selection(selection)
      :error -> UsableModel.select_local(settings, opts)
    end
  end

  defp hosted_selection(settings, opts) do
    case Keyword.fetch(opts, :hosted_selection) do
      {:ok, selection} -> normalize_selection(selection)
      :error -> UsableModel.select_hosted(settings)
    end
  end

  defp normalize_selection(nil), do: {:error, :no_usable_model}
  defp normalize_selection({:ok, selection}), do: {:ok, selection}
  defp normalize_selection({:error, :no_usable_model} = error), do: error
  defp normalize_selection(selection) when is_map(selection), do: {:ok, selection}

  defp enable(model_state, selection, opts) do
    values = %{
      "intent.direct_answer_model_enabled" => true,
      "intent.model_assist_enabled" => true,
      "model_preferences.primary" => selection.profile
    }

    context =
      opts
      |> Keyword.get(:context, %{})
      |> Map.merge(%{
        actor: "first-run",
        enabled_by: :detection,
        profile: selection.profile,
        provider: selection.provider,
        provider_class: selection.provider_class
      })

    # Pending-before-enable is the fail-closed order for hosted egress. A
    # crash here may repeat a disclosure, but can never enable transport with
    # no durable disclosure record.
    :ok = Disclosure.mark_pending(selection)

    case Store.put_user_settings_if_absent(values, context) do
      {:ok, provenance} ->
        cancel_unneeded_disclosure(provenance)

        {:ok,
         %{
           state: :auto_enabled,
           model_state: model_state,
           selection: selection,
           provenance: provenance
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cancel_unneeded_disclosure(%{written: written}) do
    if "intent.direct_answer_model_enabled" in written,
      do: :ok,
      else: Disclosure.cancel_pending()
  end

  defp result(state, model_state, selection) do
    {:ok, %{state: state, model_state: model_state, selection: selection, provenance: nil}}
  end

  defp repair_state(:local_ready), do: :nothing_detected
  defp repair_state(model_state), do: Map.fetch!(@repair_states, model_state)

  defp resolved_settings(opts) do
    case {Keyword.fetch(opts, :settings), Keyword.fetch(opts, :user_settings)} do
      {{:ok, settings}, {:ok, user_settings}} -> {:ok, settings, user_settings}
      _other -> Store.resolved_settings()
    end
  end

  defp req_started?(opts) do
    ready? = Keyword.get(opts, :req_started?, &default_req_started?/0)
    ready?.()
  end

  defp default_req_started? do
    Enum.any?(Application.started_applications(), fn {app, _description, _version} ->
      app == :req
    end)
  end
end
