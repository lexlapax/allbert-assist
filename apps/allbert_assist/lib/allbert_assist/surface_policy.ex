defmodule AllbertAssist.SurfacePolicy do
  @moduledoc """
  Settings-backed report-shape policy for operator and public surfaces.

  This module only governs DTO display shape: render mode, redaction profile,
  row bounds, and whether a raw/operator report requires an explicit affordance.
  It does not grant action exposure, lower Security Central floors, or bypass
  confirmation.
  """

  alias AllbertAssist.Settings.Store

  @surface_ids ~w(live_view cli tui mcp_stdio mcp_http acp acp_stdio openai_api)
  @default_policy %{
    render_mode: :assistant_summary,
    redaction_profile: :standard,
    max_rows: 25,
    raw_requires_affordance?: true,
    source: :default
  }

  @spec surface_ids() :: [String.t(), ...]
  def surface_ids, do: @surface_ids

  @spec render_mode(String.t(), map(), map()) :: :assistant_summary | :operator_report
  def render_mode(action_name, params, context) do
    action_name
    |> report_policy(params, context)
    |> Map.fetch!(:render_mode)
  end

  @spec report_policy(String.t(), map(), map()) :: map()
  def report_policy(action_name, params, context) do
    requested = requested_render_mode(params, context)
    policy = policy_for(surface_id(params, context), action_name)

    effective_render_mode =
      cond do
        requested != :operator_report ->
          :assistant_summary

        policy.render_mode != :operator_report ->
          :assistant_summary

        policy.raw_requires_affordance? and not explicit_affordance?(params, context) ->
          :assistant_summary

        true ->
          :operator_report
      end

    Map.put(policy, :render_mode, effective_render_mode)
  end

  @spec policy_for(String.t(), String.t()) :: map()
  def policy_for(surface, action_name) do
    case Store.resolved_settings() do
      {:ok, settings, _user_settings} -> effective_policy(settings, surface, action_name)
      {:error, _reason} -> @default_policy
    end
  end

  @spec dto(map(), map()) :: map()
  def dto(params \\ %{}, context \\ %{}) do
    with {:ok, settings, _user_settings} <- Store.resolved_settings() do
      surface = field(params, :surface) || surface_id(params, context)
      action_name = field(params, :action) || field(params, :action_name)

      {:ok,
       %{
         schema_version: get_in(settings, ["surface_policy", "schema_version"]),
         defaults: default_dto(settings),
         surfaces: surface_rows(settings),
         effective: effective_dto(settings, surface, action_name)
       }}
    end
  end

  defp effective_policy(settings, surface, action_name) do
    defaults = defaults(settings)
    override = override(settings, surface, action_name)
    source = if override == %{}, do: :default, else: :override

    defaults
    |> Map.merge(override)
    |> normalize_policy()
    |> Map.put(:surface, normalize_surface(surface))
    |> Map.put(:action_name, normalize_action(action_name))
    |> Map.put(:source, source)
  end

  defp default_dto(settings) do
    settings
    |> defaults()
    |> normalize_policy()
    |> Map.drop([:surface, :action_name])
  end

  defp effective_dto(_settings, _surface, action_name) when action_name in [nil, ""], do: nil

  defp effective_dto(settings, surface, action_name) do
    policy = effective_policy(settings, surface, action_name)

    Map.put(policy, :raw_operator_report_allowed?, policy.render_mode == :operator_report)
  end

  defp surface_rows(settings) do
    configured = get_in(settings, ["surface_policy", "surfaces"]) || %{}

    @surface_ids
    |> Enum.flat_map(fn surface ->
      actions = Map.get(configured, surface, %{})

      Enum.map(actions, fn {action_name, attrs} ->
        settings
        |> effective_policy(surface, action_name)
        |> Map.merge(%{
          surface: surface,
          action_name: action_name,
          configured?: attrs != %{}
        })
      end)
    end)
    |> Enum.sort_by(&{&1.surface, &1.action_name})
  end

  defp defaults(settings) do
    settings
    |> get_in(["surface_policy", "defaults"])
    |> case do
      defaults when is_map(defaults) -> defaults
      _other -> %{}
    end
  end

  defp override(settings, surface, action_name) when action_name not in [nil, ""] do
    get_in(settings, [
      "surface_policy",
      "surfaces",
      normalize_surface(surface),
      normalize_action(action_name)
    ]) ||
      %{}
  end

  defp override(_settings, _surface, _action_name), do: %{}

  defp normalize_policy(policy) when is_map(policy) do
    %{
      render_mode: render_mode_value(field(policy, :render_mode)),
      redaction_profile: redaction_profile(field(policy, :redaction_profile)),
      max_rows: max_rows(field(policy, :max_rows)),
      raw_requires_affordance?: truthy?(field(policy, :raw_requires_affordance))
    }
  end

  defp requested_render_mode(params, context) do
    case field(params, :render_mode) || field(params, :mode) || field(context, :render_mode) do
      value when value in [:operator_report, "operator_report", :raw, "raw"] -> :operator_report
      _other -> :assistant_summary
    end
  end

  defp render_mode_value(value) when value in [:operator_report, "operator_report"],
    do: :operator_report

  defp render_mode_value(_value), do: :assistant_summary

  defp redaction_profile(value) when value in [:strict, "strict"], do: :strict
  defp redaction_profile(_value), do: :standard

  defp max_rows(value) when is_integer(value), do: value
  defp max_rows(_value), do: Map.fetch!(@default_policy, :max_rows)

  defp explicit_affordance?(params, context) do
    Enum.any?([params, context, field(context, :request, %{})], fn source ->
      truthy?(field(source, :surface_policy_affordance)) ||
        truthy?(field(source, :surface_policy_affordance?)) ||
        truthy?(field(source, :explicit_affordance)) ||
        truthy?(field(source, :explicit_affordance?)) ||
        truthy?(field(source, :raw_affordance)) ||
        truthy?(field(source, :raw_affordance?))
    end)
  end

  defp surface_id(params, context) do
    field(params, :surface) ||
      field(context, :surface_id) ||
      public_protocol_surface(context) ||
      channel_surface(field(context, :channel)) ||
      surface_label(field(context, :surface)) ||
      "live_view"
  end

  defp public_protocol_surface(%{public_protocol: %{surface: surface}}), do: surface
  defp public_protocol_surface(%{public_protocol: %{"surface" => surface}}), do: surface
  defp public_protocol_surface(_context), do: nil

  defp channel_surface(channel) when channel in [:cli, "cli"], do: "cli"
  defp channel_surface(channel) when channel in [:tui, "tui"], do: "tui"
  defp channel_surface(channel) when channel in [:live_view, "live_view"], do: "live_view"
  defp channel_surface(channel) when channel in [:mcp_stdio, "mcp_stdio"], do: "mcp_stdio"
  defp channel_surface(channel) when channel in [:mcp_http, "mcp_http"], do: "mcp_http"
  defp channel_surface(channel) when channel in [:acp_stdio, "acp_stdio"], do: "acp_stdio"
  defp channel_surface(channel) when channel in [:openai_api, "openai_api"], do: "openai_api"
  defp channel_surface(_channel), do: nil

  defp surface_label("mix " <> _rest), do: "cli"
  defp surface_label("/workspace"), do: "live_view"
  defp surface_label(surface) when surface in @surface_ids, do: surface
  defp surface_label(_surface), do: nil

  defp normalize_surface(surface) when surface in @surface_ids, do: surface

  defp normalize_surface(surface),
    do: surface |> to_string() |> String.replace(~r/[^a-z0-9_]/, "_")

  defp normalize_action(action_name) do
    action_name
    |> to_string()
    |> String.replace(~r/[^a-z0-9_]/, "_")
  end

  defp field(map, key, default \\ nil)

  defp field(%{} = map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_map, _key, default), do: default

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(1), do: true
  defp truthy?(_value), do: false
end
