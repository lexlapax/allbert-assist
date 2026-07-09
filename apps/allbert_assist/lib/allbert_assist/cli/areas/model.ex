defmodule AllbertAssist.CLI.Areas.Model do
  @moduledoc """
  Release-safe `model` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.model` and `allbert admin model`:
  `dispatch/2` parses the sub-argv, routes to the same
  `list_provider_profiles`/`list_model_profiles`/`set_active_model_profile`/
  `doctor_*` registered actions the Mix task used, and returns
  `{rendered_output, exit_code}` — no `Mix.*` calls, so it runs inside the
  packaged release. `Mix.Tasks.Allbert.Model` is a thin wrapper that prints the
  output through `Mix.shell/0`.
  """

  alias AllbertAssist.Actions.Helper, as: ActionHelper
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Settings
  alias AllbertAssist.Surfaces.ContextBuilder

  # M8.6: the canonical dispatch prefix is plural `admin models` (Commands.@operator);
  # singular `admin model` is reserved for the detect/install/pull action paths, so the
  # help must name the plural forms it actually accepts.
  @usage """
  Usage:
    allbert admin models list
    allbert admin models use PROFILE [--enable-assist]
    allbert admin models doctor PROFILE
  """

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    ctx = context || default_context()

    result =
      try do
        route(argv, ctx)
      catch
        {:model_error, message} -> {:error, {:message, message}}
      end

    render(result)
  end

  defp default_context, do: ContextBuilder.cli_context(surface: "allbert admin model")

  defp route(["list"], ctx) do
    with {:ok, providers_response} <-
           completed_action("list_provider_profiles", operator_report_params(), ctx),
         {:ok, models_response} <-
           completed_action("list_model_profiles", operator_report_params(), ctx),
         {:ok, active_profile} <- Settings.get("intent.model_profile"),
         {:ok, assist_enabled?} <- Settings.get("intent.model_assist_enabled") do
      {:ok,
       {:list, providers_response.providers, models_response.models, active_profile,
        assist_enabled?}}
    end
  end

  defp route(["doctor", profile], ctx) do
    with {:ok, response} <- completed_action(doctor_action(profile), %{profile: profile}, ctx) do
      {:ok, {:doctor, response}}
    end
  end

  defp route(["use", profile | args], ctx) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [enable_assist: :boolean])

    reject_invalid!(invalid)
    reject_rest!(rest)

    params =
      %{profile: profile}
      |> maybe_put(:enable_assist, Keyword.get(opts, :enable_assist))

    with {:ok, response} <- completed_action("set_active_model_profile", params, ctx) do
      {:ok, {:use, response}}
    end
  end

  defp route(_args, _ctx), do: {:usage, @usage}

  defp render({:ok, {:list, providers, models, active_profile, assist_enabled?}}) do
    Render.ok(
      [
        "Active model profile: #{active_profile}",
        "Model-assisted intent: #{inspect(assist_enabled?)}",
        "",
        "Providers:"
      ] ++
        Enum.map(providers, fn provider ->
          "- #{provider.name}: type=#{provider.type} endpoint_kind=#{provider.endpoint_kind} enabled=#{provider.enabled} credential=#{provider.credential_status}"
        end) ++
        ["", "Models:"] ++
        Enum.map(models, fn model ->
          active = if model.name == active_profile, do: " active", else: ""

          "- #{model.name}: provider=#{model.provider} model=#{model.model} endpoint_kind=#{model.provider_endpoint_kind} credential=#{model.credential_status}#{active}"
        end)
    )
  end

  defp render({:ok, {:doctor, response}}) do
    doctor = response.doctor

    Render.ok(
      [
        response.message,
        "endpoint_kind=#{doctor.endpoint_kind}",
        "credential_ok=#{inspect(doctor.credential_ok)}",
        "endpoint_ok=#{doctor.endpoint_ok}",
        "model_available=#{inspect(doctor.model_available)}",
        "redacted_host=#{doctor.redacted_host}"
      ] ++
        voice_doctor_lines(doctor) ++
        Enum.map(doctor.diagnostics, fn diagnostic ->
          "diagnostic=#{diagnostic.code}: #{diagnostic.message}"
        end)
    )
  end

  defp render({:ok, {:use, response}}) do
    Render.ok([response.message | audit_lines(response.settings)])
  end

  defp render({:error, {:message, message}}), do: Render.error(message)
  defp render({:usage, usage}), do: Render.usage(usage)
  defp render({:error, reason}), do: Render.error("Model command failed: #{inspect(reason)}")

  defp completed_action(action_name, params, ctx) do
    ActionHelper.completed_action(action_name, params, ctx)
  end

  defp operator_report_params do
    %{render_mode: "operator_report", surface_policy_affordance: true}
  end

  defp doctor_action(profile) do
    case Settings.resolve_model_profile(profile) do
      {:ok, model_profile} ->
        if voice_capable?(model_profile),
          do: "doctor_voice_provider",
          else: "doctor_model_profile"

      {:error, _reason} ->
        "doctor_model_profile"
    end
  end

  defp voice_capable?(%{capabilities: capabilities}) when is_list(capabilities) do
    Enum.any?(capabilities, &(&1 in ["speech_to_text", "text_to_speech"]))
  end

  defp voice_capable?(_profile), do: false

  defp voice_doctor_lines(%{provider_capabilities: capabilities} = doctor) do
    [
      "provider_capabilities=#{Enum.join(capabilities, ",")}",
      "provider_deployment_mode=#{inspect(doctor.provider_deployment_mode)}",
      "speech_to_text_supported=#{inspect(doctor.speech_to_text_supported)}",
      "text_to_speech_supported=#{inspect(doctor.text_to_speech_supported)}",
      "audio_formats_supported=#{inspect(doctor.audio_formats_supported)}",
      "audio_sample_rates_supported=#{inspect(doctor.audio_sample_rates_supported)}"
    ]
  end

  defp voice_doctor_lines(_doctor), do: []

  defp audit_lines(settings) do
    settings
    |> Enum.flat_map(& &1.diagnostics)
    |> Enum.flat_map(fn
      %{audit_path: audit_path} -> ["Audit: #{audit_path}"]
      _diagnostic -> []
    end)
  end

  defp reject_invalid!([]), do: :ok
  defp reject_invalid!(invalid), do: fail!("Invalid option(s): #{inspect(invalid)}")

  defp reject_rest!([]), do: :ok
  defp reject_rest!(rest), do: fail!("Unexpected argument(s): #{Enum.join(rest, " ")}")

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @spec fail!(String.t()) :: no_return()
  defp fail!(message), do: throw({:model_error, message})
end
