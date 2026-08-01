defmodule AllbertAssist.FirstRun.Disclosure do
  @moduledoc """
  Durable, per-surface disclosure state for detection-based enablement.

  A failed render leaves the marker pending. Hosted callers invoke
  `render_and_ack/2` before transport, and provider-call actions invoke
  `authorize_transport/2` against the exact route immediately before egress.
  A route change invalidates an acknowledgement instead of treating a stale
  surface-level boolean as authority.

  ADR 0087's lifecycle continues after first run here as DirectAnswer's ongoing
  provider-egress admission seam.
  """

  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Models

  @surfaces ~w(web tui cli)
  @max_route_count 3
  @route_usages [:primary, :fallback, :fanout_synthesis]

  @type provider_class :: :local | :hosted
  @type route :: %{
          optional(:usage) => :primary | :fallback | :fanout_synthesis,
          optional(:usages) => [:primary | :fallback | :fanout_synthesis],
          required(:profile) => String.t(),
          required(:provider) => String.t(),
          required(:provider_class) => provider_class()
        }

  @spec mark_pending(%{
          required(:profile) => term(),
          required(:provider) => term(),
          required(:provider_class) => atom()
        }) :: :ok | {:error, term()}
  def mark_pending(selection) when is_map(selection), do: reconcile(selection)

  @doc """
  Reconcile every surface to one exact provider-call route set.

  This operation is idempotent. A pending or acknowledged record is preserved
  only while the ordered, bounded route set still matches. Any route-set change
  becomes pending on every surface.
  """
  @spec reconcile(route() | map()) :: :ok | {:error, term()}
  def reconcile(selection) when is_map(selection) do
    reconcile_routes([selection])
  end

  def reconcile(_selection), do: {:error, :invalid_disclosure_route}

  @doc "Reconcile the deduplicated bounded callable model-route set."
  @spec reconcile_routes([route() | map()]) :: :ok | {:error, term()}
  def reconcile_routes(selections) when is_list(selections) and selections != [] do
    with {:ok, routes} <- normalize_routes(selections),
         true <- length(routes) <= @max_route_count do
      marker = FirstRun.read_marker()
      current = Map.get(marker, "model_disclosure", %{})

      disclosures =
        Map.new(@surfaces, fn surface ->
          existing = Map.get(current, surface, %{})
          {surface, reconcile_record(existing, routes)}
        end)

      FirstRun.merge_marker(%{"model_disclosure" => disclosures})
    else
      false -> {:error, :disclosure_route_set_too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  def reconcile_routes(_selections), do: {:error, :invalid_disclosure_route_set}

  @doc "Reconcile disclosure state to a resolved runtime model profile."
  @spec reconcile_profile(map()) :: :ok | {:error, term()}
  def reconcile_profile(profile) when is_map(profile) do
    with {:ok, route} <- route_for_profile(profile), do: reconcile(route)
  end

  def reconcile_profile(_profile), do: {:error, :invalid_model_profile}

  @doc """
  Reconcile the currently callable DirectAnswer and fan-out synthesis routes
  when model answers are enabled. This retained name is the backward-compatible
  central post-settings/boot hook; disabled configurations leave the dormant
  marker alone and gain no transport authority from it.
  """
  @spec reconcile_current_direct_answer_route(route() | map() | nil) :: :ok | {:error, term()}
  def reconcile_current_direct_answer_route(fallback_direct_answer_route \\ nil) do
    with {:ok, true} <- Settings.get("intent.direct_answer_model_enabled"),
         {:ok, routes} <- current_model_routes(fallback_direct_answer_route) do
      reconcile_routes(routes)
    else
      {:ok, false} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Resolve the exact bounded union of callable DirectAnswer and synthesis routes."
  @spec current_model_routes() :: {:ok, [route()]} | {:error, term()}
  def current_model_routes, do: current_model_routes(nil)

  defp current_model_routes(fallback_direct_answer_route) do
    with {:ok, direct_answer_routes} <-
           current_direct_answer_routes_or(fallback_direct_answer_route),
         {:ok, synthesis_routes} <- optional_callable_routes(&current_fanout_synthesis_routes/0) do
      case deduplicate_routes(direct_answer_routes ++ synthesis_routes) do
        [] -> {:error, :no_callable_disclosure_routes}
        routes when length(routes) <= @max_route_count -> {:ok, routes}
        _too_many -> {:error, :disclosure_route_set_too_large}
      end
    end
  end

  defp current_direct_answer_routes_or(fallback_route) do
    case current_direct_answer_routes() do
      {:ok, routes} ->
        {:ok, routes}

      {:error, {:no_capable_profile, _diagnostic}} when is_map(fallback_route) ->
        with {:ok, route} <- normalize_route(fallback_route) do
          {:ok, [with_usage(route, :primary)]}
        end

      {:error, {:no_capable_profile, _diagnostic}} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Resolve the exact bounded route set DirectAnswer may call this turn."
  @spec current_direct_answer_routes() :: {:ok, [route()]} | {:error, term()}
  def current_direct_answer_routes do
    with {:ok, [primary | rest]} <- Models.candidates_for(:direct_answer),
         {:ok, primary_route} <- route_for_profile(primary.profile) do
      routes = [with_usage(primary_route, :primary)]

      case callable_fallback(primary.profile, List.first(rest)) do
        %{profile: fallback_profile} ->
          append_direct_answer_fallback(routes, fallback_profile)

        nil ->
          {:ok, routes}
      end
    end
  end

  defp append_direct_answer_fallback(routes, fallback_profile) do
    with {:ok, fallback_route} <- route_for_profile(fallback_profile) do
      {:ok, routes ++ [with_usage(fallback_route, :fallback)]}
    end
  end

  defp current_fanout_synthesis_routes do
    with {:ok, %{profile: profile}} <- Models.for(:fanout_synthesis),
         {:ok, route} <- route_for_profile(profile) do
      {:ok, [with_usage(route, :fanout_synthesis)]}
    end
  end

  defp optional_callable_routes(resolver) do
    case resolver.() do
      {:ok, routes} -> {:ok, routes}
      {:error, {:no_capable_profile, _diagnostic}} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Authorize one resolved profile for its current request surface.

  Local routes do not require acknowledgement. Hosted routes fail closed unless
  the exact, currently callable bounded route set is acknowledged on web, TUI,
  or CLI. Non-presenting surfaces may reuse that exact acknowledgement from a
  local operator-control surface; without one they fail closed and seed a local
  pending disclosure for repair.
  """
  @spec authorize_transport(map(), map()) :: :ok | {:error, term()}
  def authorize_transport(profile, context) when is_map(profile) and is_map(context) do
    with {:ok, route} <- route_for_profile(profile) do
      authorize_transport_route(route, disclosure_surface(context))
    end
  end

  def authorize_transport(_profile, _context), do: {:error, :invalid_transport_route}

  @doc "Return whether an exact route has been acknowledged on one surface."
  @spec acknowledged_for?(atom() | String.t(), route() | map()) :: boolean()
  def acknowledged_for?(surface, selection) when is_map(selection) do
    with {:ok, route} <- normalize_route(selection),
         normalized_surface when normalized_surface in @surfaces <- normalize_surface(surface) do
      disclosure = record(normalized_surface)
      disclosure["state"] == "acknowledged" and route_member?(record_routes(disclosure), route)
    else
      _other -> false
    end
  end

  def acknowledged_for?(_surface, _selection), do: false

  @doc "Resolve the local disclosure surface carried by a runtime action context."
  @spec disclosure_surface(map()) :: String.t() | nil
  def disclosure_surface(context) when is_map(context) do
    request = map_value(context, :request)

    request
    |> map_value(:channel)
    |> case do
      nil -> map_value(context, :channel)
      channel -> channel
    end
    |> known_surface()
  end

  def disclosure_surface(_context), do: nil

  @doc "Project a resolved model profile to the non-secret route fingerprint."
  @spec route_for_profile(map()) :: {:ok, route()} | {:error, term()}
  def route_for_profile(profile) when is_map(profile) do
    normalize_route(%{
      profile: map_value(profile, :name) || map_value(profile, :profile),
      provider: map_value(profile, :provider),
      provider_class: provider_class(profile)
    })
  end

  def route_for_profile(_profile), do: {:error, :invalid_model_profile}

  defp callable_fallback(_primary, nil), do: nil

  defp callable_fallback(primary, fallback) do
    if fallback_enabled?() and fallback_boundary_allowed?(primary, fallback.profile) do
      fallback
    end
  end

  defp fallback_enabled?, do: match?({:ok, true}, Settings.get("models.fallback.enabled"))

  defp fallback_boundary_allowed?(primary, fallback) do
    not local_profile?(primary) or local_profile?(fallback) or
      match?({:ok, true}, Settings.get("models.fallback.allow_local_to_hosted"))
  end

  defp local_profile?(profile) do
    map_value(profile, :provider_endpoint_kind) in [:local_endpoint, "local_endpoint"]
  end

  @spec pending?(atom() | String.t()) :: boolean()
  def pending?(surface), do: get_in(record(surface), ["state"]) == "pending"

  @spec hosted_pending?(atom() | String.t()) :: boolean()
  def hosted_pending?(surface) do
    disclosure = record(surface)

    disclosure["state"] == "pending" and
      Enum.any?(record_routes(disclosure), &(&1.provider_class == :hosted))
  end

  @spec text(atom() | String.t()) :: String.t() | nil
  def text(surface) do
    case pending_delivery(surface) do
      {:ok, delivery} -> delivery.text
      :none -> nil
    end
  end

  @spec render_and_ack(atom() | String.t(), (String.t() -> term())) ::
          :ok | {:error, term()}
  def render_and_ack(surface, output_fun) when is_function(output_fun, 1) do
    case pending_delivery(surface) do
      :none ->
        :ok

      {:ok, delivery} ->
        try do
          case output_fun.(delivery.text) do
            {:error, reason} -> {:error, {:disclosure_render_failed, reason}}
            _delivered -> acknowledge_exact(surface, delivery.route_set_digest)
          end
        rescue
          exception -> {:error, {:disclosure_render_failed, exception.__struct__}}
        catch
          kind, reason -> {:error, {:disclosure_render_failed, {kind, reason}}}
        end
    end
  end

  @spec acknowledge(atom() | String.t()) :: :ok | {:error, :stale_disclosure_route}
  def acknowledge(surface) do
    case pending_delivery(surface) do
      {:ok, delivery} -> acknowledge_exact(surface, delivery.route_set_digest)
      :none -> :ok
    end
  end

  @spec prepare_web_delivery() :: {:ok, %{text: String.t(), handle: String.t()}} | :none
  def prepare_web_delivery do
    case pending_delivery(:web) do
      :none ->
        :none

      {:ok, delivery} ->
        handle = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
        marker = FirstRun.read_marker()
        disclosures = Map.get(marker, "model_disclosure", %{})

        web =
          disclosures
          |> Map.get("web", %{})
          |> Map.put("delivery_handle", handle)
          |> Map.put("delivery_route_set_digest", delivery.route_set_digest)

        :ok = FirstRun.merge_marker(%{"model_disclosure" => Map.put(disclosures, "web", web)})
        {:ok, %{text: delivery.text, handle: handle}}
    end
  end

  @spec acknowledge_web(String.t()) :: :ok | {:error, :stale_delivery_handle}
  def acknowledge_web(handle) when is_binary(handle) do
    disclosure = record(:web)
    expected = disclosure["delivery_handle"]
    route_set_digest = disclosure["delivery_route_set_digest"]

    if is_binary(expected) and byte_size(expected) == byte_size(handle) and
         Plug.Crypto.secure_compare(expected, handle) and is_binary(route_set_digest) do
      case acknowledge_exact(:web, route_set_digest) do
        :ok -> :ok
        {:error, :stale_disclosure_route} -> {:error, :stale_delivery_handle}
      end
    else
      {:error, :stale_delivery_handle}
    end
  end

  def acknowledge_web(_handle), do: {:error, :stale_delivery_handle}

  @spec cancel_pending() :: :ok
  def cancel_pending, do: FirstRun.merge_marker(%{"model_disclosure" => %{}})

  defp pending_delivery(surface) do
    case record(surface) do
      %{"state" => "pending"} = disclosure ->
        {:ok,
         %{
           text: disclosure_text(disclosure),
           route_set_digest: record_route_set_digest(disclosure)
         }}

      _other ->
        :none
    end
  end

  defp acknowledge_exact(surface, expected_digest) do
    surface = normalize_surface(surface)
    marker = FirstRun.read_marker()

    case get_in(marker, ["model_disclosure", surface]) do
      %{"state" => "pending"} = disclosure ->
        if secure_digest_match?(record_route_set_digest(disclosure), expected_digest) do
          FirstRun.merge_marker(%{
            "model_disclosure" =>
              marker
              |> Map.get("model_disclosure", %{})
              |> Map.put(surface, Map.put(disclosure, "state", "acknowledged"))
          })
        else
          {:error, :stale_disclosure_route}
        end

      _missing_or_not_pending ->
        {:error, :stale_disclosure_route}
    end
  end

  defp authorize_transport_route(%{provider_class: :local}, _surface), do: :ok

  defp authorize_transport_route(%{provider_class: :hosted} = route, surface) do
    with {:ok, expected_routes} <- current_model_routes(),
         true <- route_member?(expected_routes, route) do
      authorize_route_set(route, expected_routes, surface)
    else
      false ->
        {:error,
         {:hosted_route_not_current,
          %{profile: route.profile, provider: route.provider, surface: surface || :unknown}}}

      {:error, reason} ->
        {:error, {:hosted_route_unavailable, reason}}
    end
  end

  defp authorize_route_set(route, expected_routes, surface) when surface in @surfaces do
    if acknowledged_route_set?(surface, expected_routes) do
      :ok
    else
      pend_for_retry(expected_routes)

      {:error,
       {:hosted_disclosure_required,
        %{profile: route.profile, provider: route.provider, surface: surface}}}
    end
  end

  defp authorize_route_set(route, expected_routes, _unknown_surface) do
    if Enum.any?(@surfaces, &acknowledged_route_set?(&1, expected_routes)) do
      :ok
    else
      pend_for_retry(expected_routes)

      {:error,
       {:hosted_disclosure_unavailable,
        %{profile: route.profile, provider: route.provider, surface: :unknown}}}
    end
  end

  defp acknowledged_route_set?(surface, expected_routes) do
    disclosure = record(surface)

    disclosure["state"] == "acknowledged" and
      route_sets_match?(record_routes(disclosure), expected_routes)
  end

  defp pend_for_retry(routes) do
    _result = reconcile_routes(routes)
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp reconcile_record(existing, routes) do
    if existing["state"] in ["pending", "acknowledged"] and
         route_sets_match?(record_routes(existing), routes) do
      existing
    else
      route_set_record(routes, "pending")
    end
  end

  defp route_set_record([primary | _rest] = routes, state) do
    primary
    |> stored_route()
    |> Map.merge(%{
      "state" => state,
      "routes" => Enum.map(routes, &stored_route/1),
      "route_set_digest" => route_set_digest(routes)
    })
  end

  defp stored_route(route) do
    %{
      "profile" => route.profile,
      "provider" => route.provider,
      "provider_class" => Atom.to_string(route.provider_class),
      "usage" => route |> Map.get(:usage, :primary) |> Atom.to_string(),
      "usages" => route |> Map.get(:usages, [:primary]) |> Enum.map(&Atom.to_string/1)
    }
  end

  defp record_routes(%{"routes" => routes}) when is_list(routes) do
    case normalize_routes(routes) do
      {:ok, normalized} -> normalized
      {:error, _reason} -> []
    end
  end

  defp record_routes(%{} = legacy_record) do
    case normalize_route(legacy_record) do
      {:ok, route} -> [route]
      {:error, _reason} -> []
    end
  end

  defp record_routes(_record), do: []

  defp route_member?(routes, expected) do
    Enum.any?(routes, &same_route?(&1, expected))
  end

  defp route_sets_match?(left, right) do
    length(left) == length(right) and
      Enum.zip(left, right) |> Enum.all?(fn {a, b} -> same_route_entry?(a, b) end)
  end

  defp same_route?(left, right) do
    left.profile == right.profile and left.provider == right.provider and
      left.provider_class == right.provider_class
  end

  defp same_route_entry?(left, right) do
    same_route?(left, right) and Map.get(left, :usages, []) == Map.get(right, :usages, [])
  end

  defp normalize_route(selection) do
    profile = map_value(selection, :profile)
    provider = map_value(selection, :provider)
    provider_class = normalize_provider_class(map_value(selection, :provider_class))

    with {:ok, usages} <- normalize_usages(selection),
         true <-
           is_binary(profile) and profile != "" and is_binary(provider) and provider != "" and
             provider_class in [:local, :hosted] do
      {:ok,
       %{
         profile: profile,
         provider: provider,
         provider_class: provider_class,
         usage: hd(usages),
         usages: usages
       }}
    else
      _invalid -> {:error, :invalid_disclosure_route}
    end
  end

  defp normalize_routes(selections) do
    selections
    |> Enum.reduce_while({:ok, []}, fn selection, {:ok, routes} ->
      case normalize_route(selection) do
        {:ok, route} -> {:cont, {:ok, append_unless_duplicate(routes, route)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp deduplicate_routes(routes), do: Enum.reduce(routes, [], &append_unless_duplicate(&2, &1))

  defp append_unless_duplicate(routes, route) do
    case Enum.find_index(routes, &same_route?(&1, route)) do
      nil -> routes ++ [route]
      index -> List.update_at(routes, index, &merge_route_usages(&1, route))
    end
  end

  defp merge_route_usages(existing, additional) do
    usages = ordered_usages(existing.usages ++ additional.usages)
    %{existing | usage: hd(usages), usages: usages}
  end

  defp with_usage(route, usage), do: %{route | usage: usage, usages: [usage]}

  defp normalize_usages(selection) do
    values = map_value(selection, :usages)

    usages =
      case values do
        values when is_list(values) -> Enum.map(values, &normalize_usage/1)
        _missing -> [normalize_usage(map_value(selection, :usage))]
      end

    if usages != [] and Enum.all?(usages, &(&1 in @route_usages)) do
      {:ok, ordered_usages(usages)}
    else
      {:error, :invalid_disclosure_route_usage}
    end
  end

  defp ordered_usages(usages) do
    @route_usages
    |> Enum.filter(&(&1 in usages))
  end

  defp normalize_provider_class(value) when value in [:local, "local"], do: :local
  defp normalize_provider_class(value) when value in [:hosted, "hosted"], do: :hosted
  defp normalize_provider_class(_value), do: nil

  defp normalize_usage(value) when value in [:fallback, "fallback"], do: :fallback

  defp normalize_usage(value) when value in [:fanout_synthesis, "fanout_synthesis"],
    do: :fanout_synthesis

  defp normalize_usage(value) when value in [:primary, "primary", nil], do: :primary
  defp normalize_usage(_value), do: :invalid

  defp provider_class(profile) do
    case map_value(profile, :provider_endpoint_kind) || map_value(profile, :endpoint_kind) do
      value when value in [:local_endpoint, "local_endpoint"] -> :local
      _other -> :hosted
    end
  end

  defp record_route_set_digest(record), do: record |> record_routes() |> route_set_digest()

  defp route_set_digest(routes) do
    canonical =
      Enum.map_join(routes, "\n", fn route ->
        Enum.join(
          [
            route.profile,
            route.provider,
            Atom.to_string(route.provider_class),
            Enum.map_join(route.usages, ",", &Atom.to_string/1)
          ],
          <<0>>
        )
      end)

    :sha256
    |> :crypto.hash(canonical)
    |> Base.encode16(case: :lower)
  end

  defp secure_digest_match?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: Plug.Crypto.secure_compare(left, right)

  defp secure_digest_match?(_left, _right), do: false

  defp record(surface) do
    FirstRun.read_marker()
    |> get_in(["model_disclosure", normalize_surface(surface)])
    |> case do
      %{} = disclosure -> disclosure
      _missing -> %{}
    end
  end

  defp disclosure_text(disclosure) do
    routes =
      case Map.get(disclosure, "routes") do
        routes when is_list(routes) and routes != [] -> routes
        _legacy -> [disclosure]
      end

    Enum.map_join(routes, "\n", &route_disclosure_text/1)
  end

  defp route_disclosure_text(route) do
    route
    |> stored_route_usages()
    |> Enum.map_join("\n", &usage_disclosure_text(&1, route))
  end

  defp usage_disclosure_text(:fallback, %{
         "profile" => profile,
         "provider" => provider,
         "provider_class" => "hosted"
       }) do
    "Allbert may use #{profile} from #{provider} as the configured DirectAnswer failover. " <>
      "If the primary model fails, your message may leave this device for #{provider}. Change the fallback in Models, or disable cross-boundary fallback with `allbert admin settings set models.fallback.allow_local_to_hosted false`."
  end

  defp usage_disclosure_text(:primary, %{
         "profile" => profile,
         "provider" => provider,
         "provider_class" => "hosted"
       }) do
    "Your configured DirectAnswer route uses #{profile} from #{provider}. " <>
      "Your message will leave this device for #{provider}. Change the model in Models, or disable model answers with `allbert admin settings set intent.direct_answer_model_enabled false`."
  end

  defp usage_disclosure_text(:fallback, %{
         "profile" => profile,
         "provider" => provider,
         "provider_class" => "local"
       }) do
    "Allbert may use #{profile} from #{provider} as the configured local DirectAnswer failover. " <>
      "Inference uses your configured local endpoint. Change the fallback in Models, or disable model fallback with `allbert admin settings set models.fallback.enabled false`."
  end

  defp usage_disclosure_text(:primary, %{
         "profile" => profile,
         "provider" => provider,
         "provider_class" => "local"
       }) do
    "Your configured DirectAnswer route uses #{profile} from #{provider}. " <>
      "Inference uses your configured local endpoint. Change the model in Models, or disable model answers with `allbert admin settings set intent.direct_answer_model_enabled false`."
  end

  defp usage_disclosure_text(:fanout_synthesis, %{
         "profile" => profile,
         "provider" => provider,
         "provider_class" => "hosted"
       }) do
    "Your configured fan-out report synthesis route uses #{profile} from #{provider}. " <>
      "Joined child results may leave this device for #{provider}. Change `model_preferences.tasks.fanout_synthesis`, or disable model answers with `allbert admin settings set intent.direct_answer_model_enabled false`."
  end

  defp usage_disclosure_text(:fanout_synthesis, %{
         "profile" => profile,
         "provider" => provider,
         "provider_class" => "local"
       }) do
    "Your configured fan-out report synthesis route uses #{profile} from #{provider}. " <>
      "Inference uses your configured local endpoint. Change `model_preferences.tasks.fanout_synthesis`, or disable model answers with `allbert admin settings set intent.direct_answer_model_enabled false`."
  end

  defp stored_route_usages(route) do
    route
    |> map_value(:usages)
    |> case do
      values when is_list(values) -> Enum.map(values, &normalize_usage/1)
      _missing -> [normalize_usage(map_value(route, :usage))]
    end
    |> ordered_usages()
  end

  defp known_surface(value) do
    case normalize_surface(value) do
      "live_view" -> "web"
      surface when surface in @surfaces -> surface
      _other -> nil
    end
  end

  defp normalize_surface(surface) when is_atom(surface), do: Atom.to_string(surface)
  defp normalize_surface(surface) when is_binary(surface), do: String.downcase(surface)
  defp normalize_surface(_surface), do: nil

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_value(_map, _key), do: nil
end
