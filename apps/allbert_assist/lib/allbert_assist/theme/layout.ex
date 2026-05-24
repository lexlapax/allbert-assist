defmodule AllbertAssist.Theme.Layout do
  @moduledoc """
  v0.35 workspace layout override parser and validator.

  Layout data is local YAML under Allbert Home. It can reorder or hide known
  launcher destinations and pin known panels into Canvas destinations, but it
  never creates routes, components, actions, routing context, or permissions.
  """

  alias AllbertAssist.App.CoreApp
  alias AllbertAssist.Runtime.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.YamlCodec
  alias AllbertAssist.Surface
  alias AllbertAssist.Workspace.Catalog

  @allowed_keys ~w[default_destination launcher_order hidden_destinations panel_pins]
  @max_diagnostics 8
  @max_message_length 180
  @non_hideable_destinations MapSet.new(["output", "workspace:settings"])

  @type layout :: %{
          basename: String.t(),
          default_destination: String.t(),
          diagnostics: [String.t()],
          enabled?: boolean(),
          fingerprint: String.t() | nil,
          hidden_destinations: [String.t()],
          launcher_order: [String.t()],
          mtime: integer() | nil,
          panel_pins: map(),
          status: atom()
        }

  @spec current(keyword() | map()) :: layout()
  def current(context \\ %{}) do
    enabled? = setting("workspace.layout.override_enabled", false)

    if enabled? do
      path = Path.join(Paths.workspace_root(), "layout.yaml")
      load(path, context_map(context))
    else
      result(:disabled, %{enabled?: false})
    end
  end

  @spec default_destination(keyword() | map()) :: String.t()
  def default_destination(context \\ %{}) do
    case current(context) do
      %{enabled?: true, status: status, default_destination: destination}
      when status in [:present, :partial] ->
        destination

      _layout ->
        "output"
    end
  end

  @spec launcher_destinations(layout(), [map()]) :: [map()]
  def launcher_destinations(%{enabled?: true, status: status} = layout, destinations)
      when status in [:present, :partial] and is_list(destinations) do
    hidden = MapSet.new(layout.hidden_destinations)
    by_id = Map.new(destinations, &{destination_id(&1), &1})

    ordered =
      layout.launcher_order
      |> Enum.filter(&Map.has_key?(by_id, &1))
      |> Enum.map(&Map.fetch!(by_id, &1))

    ordered_ids = MapSet.new(Enum.map(ordered, &destination_id/1))

    (ordered ++ Enum.reject(destinations, &(destination_id(&1) in ordered_ids)))
    |> Enum.reject(&(destination_id(&1) in hidden))
  end

  def launcher_destinations(_layout, destinations), do: destinations

  @spec panel_pinned?(layout() | nil, String.t(), Surface.t()) :: boolean()
  def panel_pinned?(
        %{enabled?: true, status: status, panel_pins: pins},
        destination,
        %Surface{} = surface
      )
      when status in [:present, :partial] do
    destination_refs = Map.get(pins, destination, MapSet.new())
    refs = panel_refs(surface)

    Enum.any?(refs, &MapSet.member?(destination_refs, &1))
  end

  def panel_pinned?(_layout, _destination, _surface), do: false

  defp load(path, context) do
    cond do
      not File.exists?(path) ->
        result(:missing, %{
          diagnostics: ["Layout file layout.yaml is missing."],
          enabled?: true
        })

      match?({:ok, %{type: :symlink}}, File.lstat(path)) ->
        result(:invalid, %{
          diagnostics: ["Layout file layout.yaml ignored: symlinks are not allowed."],
          enabled?: true
        })

      File.dir?(path) ->
        result(:invalid, %{
          diagnostics: ["Layout file layout.yaml ignored: is a directory."],
          enabled?: true
        })

      true ->
        parse_file(path, context)
    end
  end

  defp parse_file(path, context) do
    case YamlCodec.read_file(path) do
      {:ok, %{} = yaml} ->
        yaml
        |> validate(context)
        |> then(fn attrs ->
          result(
            attrs.status,
            Map.merge(attrs, %{fingerprint: fingerprint(path), mtime: mtime(path)})
          )
        end)

      {:error, {:settings_parse_failed, {:expected_map, _other}}} ->
        result(:invalid, %{
          diagnostics: ["Layout file layout.yaml ignored: root must be a map."],
          enabled?: true
        })

      {:error, reason} ->
        result(:invalid, %{
          diagnostics: ["Layout file layout.yaml could not be parsed: #{reason_text(reason)}."],
          enabled?: true
        })
    end
  end

  defp validate(yaml, context) do
    destinations = Catalog.known_destinations(context)
    known_ids = destinations |> Enum.map(&destination_id/1) |> MapSet.new()
    panel_refs = known_panel_refs(context)

    {default_destination, default_valid?, default_diagnostics} =
      validate_default_destination(Map.get(yaml, "default_destination"), known_ids)

    {launcher_order, order_valid?, order_diagnostics} =
      yaml |> Map.get("launcher_order") |> validate_destination_list("launcher_order", known_ids)

    {hidden_destinations, hidden_valid?, hidden_diagnostics} =
      yaml
      |> Map.get("hidden_destinations")
      |> validate_hidden_destinations(known_ids)

    {panel_pins, pins_valid?, pins_diagnostics} =
      yaml |> Map.get("panel_pins") |> validate_panel_pins(known_ids, panel_refs)

    unknown_diagnostics =
      yaml
      |> Map.keys()
      |> Enum.reject(&(&1 in @allowed_keys))
      |> Enum.map(&"Layout key #{display_key(&1)} ignored: not supported by v0.35.")

    diagnostics =
      cap_diagnostics(
        unknown_diagnostics ++
          default_diagnostics ++ order_diagnostics ++ hidden_diagnostics ++ pins_diagnostics
      )

    valid? = default_valid? or order_valid? or hidden_valid? or pins_valid? or map_size(yaml) == 0

    %{
      default_destination: default_destination,
      diagnostics: diagnostics,
      enabled?: true,
      hidden_destinations: hidden_destinations,
      launcher_order: launcher_order,
      panel_pins: panel_pins,
      status: layout_status(valid?, diagnostics)
    }
  end

  defp validate_default_destination(nil, _known_ids), do: {"output", false, []}

  defp validate_default_destination(value, known_ids) when is_binary(value) do
    destination = String.trim(value)

    cond do
      destination == "" ->
        {"output", false, ["Layout default_destination ignored: destination cannot be empty."]}

      destination == "app:allbert" ->
        {"output", false,
         ["Layout default_destination ignored: app:allbert is not a layout destination."]}

      MapSet.member?(known_ids, destination) ->
        {destination, true, []}

      true ->
        {"output", false,
         ["Layout default_destination ignored: #{safe_destination(destination)} is unknown."]}
    end
  end

  defp validate_default_destination(_value, _known_ids),
    do: {"output", false, ["Layout default_destination ignored: destination must be text."]}

  defp validate_destination_list(nil, _field, _known_ids), do: {[], false, []}

  defp validate_destination_list(values, field, known_ids) when is_list(values) do
    values
    |> Enum.reduce({[], [], false}, fn value, {items, diagnostics, valid?} ->
      case validate_destination(value, known_ids) do
        {:ok, destination} ->
          {append_unique(items, destination), diagnostics, true}

        {:error, reason} ->
          {items, diagnostics ++ ["Layout #{field} entry ignored: #{reason}."], valid?}
      end
    end)
    |> then(fn {items, diagnostics, valid?} -> {items, valid?, diagnostics} end)
  end

  defp validate_destination_list(_values, field, _known_ids),
    do: {[], false, ["Layout #{field} ignored: value must be a list."]}

  defp validate_hidden_destinations(nil, _known_ids), do: {[], false, []}

  defp validate_hidden_destinations(values, known_ids) when is_list(values) do
    values
    |> Enum.reduce({[], [], false}, fn value, {items, diagnostics, valid?} ->
      case validate_destination(value, known_ids) do
        {:ok, destination} ->
          add_hidden_destination(destination, items, diagnostics, valid?)

        {:error, reason} ->
          {items, diagnostics ++ ["Layout hidden_destinations entry ignored: #{reason}."], valid?}
      end
    end)
    |> then(fn {items, diagnostics, valid?} -> {items, valid?, diagnostics} end)
  end

  defp validate_hidden_destinations(_values, _known_ids),
    do: {[], false, ["Layout hidden_destinations ignored: value must be a list."]}

  defp add_hidden_destination(destination, items, diagnostics, valid?) do
    if non_hideable_destination?(destination) do
      {items,
       diagnostics ++
         ["Layout hidden_destinations entry ignored: #{destination} is non-hideable."], valid?}
    else
      {append_unique(items, destination), diagnostics, true}
    end
  end

  defp validate_panel_pins(nil, _known_ids, _panel_refs), do: {%{}, false, []}

  defp validate_panel_pins(pins, known_ids, panel_refs) when is_map(pins) do
    pins
    |> Enum.reduce({%{}, [], false}, fn {destination, values}, {acc, diagnostics, valid?} ->
      with {:ok, destination} <- validate_destination(destination, known_ids),
           {:ok, refs, pin_diagnostics} <- validate_panel_pin_list(values, panel_refs) do
        add_panel_pins(destination, refs, pin_diagnostics, acc, diagnostics, valid?)
      else
        {:error, reason} ->
          {acc, diagnostics ++ ["Layout panel_pins destination ignored: #{reason}."], valid?}
      end
    end)
    |> then(fn {pins, diagnostics, valid?} -> {pins, valid?, diagnostics} end)
  end

  defp validate_panel_pins(_pins, _known_ids, _panel_refs),
    do: {%{}, false, ["Layout panel_pins ignored: value must be a map."]}

  defp add_panel_pins(destination, refs, pin_diagnostics, acc, diagnostics, valid?) do
    if Enum.empty?(refs) do
      {acc, diagnostics ++ pin_diagnostics, valid?}
    else
      {Map.put(acc, destination, MapSet.new(refs)), diagnostics ++ pin_diagnostics, true}
    end
  end

  defp validate_panel_pin_list(values, panel_refs) when is_list(values) do
    {refs, diagnostics} =
      Enum.reduce(values, {[], []}, fn value, {refs, diagnostics} ->
        ref = normalize_panel_ref(value)

        cond do
          is_nil(ref) ->
            {refs, diagnostics ++ ["Layout panel_pins entry ignored: panel id must be text."]}

          MapSet.member?(panel_refs, ref) ->
            {append_unique(refs, ref), diagnostics}

          true ->
            {refs,
             diagnostics ++
               ["Layout panel_pins entry ignored: #{safe_destination(ref)} is unknown."]}
        end
      end)

    {:ok, refs, diagnostics}
  end

  defp validate_panel_pin_list(_values, _panel_refs),
    do: {:ok, [], ["Layout panel_pins destination ignored: value must be a list."]}

  defp validate_destination(value, known_ids) when is_binary(value) do
    destination = String.trim(value)

    cond do
      destination == "" ->
        {:error, "destination cannot be empty"}

      destination == "app:allbert" ->
        {:error, "app:allbert is not a layout destination"}

      MapSet.member?(known_ids, destination) ->
        {:ok, destination}

      true ->
        {:error, "#{safe_destination(destination)} is unknown"}
    end
  end

  defp validate_destination(_value, _known_ids), do: {:error, "destination must be text"}

  defp known_panel_refs(context) do
    context
    |> Map.get(:panel_surfaces, [])
    |> List.wrap()
    |> Kernel.++(core_panel_surfaces())
    |> Enum.flat_map(fn
      %Surface{} = surface -> panel_refs(surface)
      _other -> []
    end)
    |> MapSet.new()
  end

  defp panel_refs(%Surface{} = surface) do
    app_id = surface.app_id |> to_string() |> String.trim()
    surface_id = surface.id |> to_string() |> String.trim()

    [surface_id, "#{app_id}.#{surface_id}"]
  end

  defp normalize_panel_ref(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" or String.contains?(value, ["/", "\\"]) do
      nil
    else
      value
    end
  end

  defp normalize_panel_ref(_value), do: nil

  defp core_panel_surfaces do
    Enum.filter(CoreApp.surfaces(), &match?(%Surface{kind: :panel}, &1))
  end

  defp destination_id(destination) when is_map(destination) do
    Map.get(destination, :id) || Map.get(destination, "id")
  end

  defp layout_status(false, _diagnostics), do: :invalid
  defp layout_status(true, []), do: :present
  defp layout_status(true, _diagnostics), do: :partial

  defp non_hideable_destination?(destination),
    do: MapSet.member?(@non_hideable_destinations, destination)

  defp result(status, attrs) do
    %{
      basename: "layout.yaml",
      default_destination: "output",
      diagnostics: [],
      enabled?: true,
      fingerprint: nil,
      hidden_destinations: [],
      launcher_order: [],
      mtime: nil,
      panel_pins: %{},
      status: status
    }
    |> Map.merge(attrs)
    |> Map.update!(:diagnostics, &cap_diagnostics/1)
  end

  defp append_unique(items, value) do
    if value in items, do: items, else: items ++ [value]
  end

  defp setting(key, default) do
    case Settings.get(key) do
      {:ok, value} -> value
      _other -> default
    end
  end

  defp context_map(context) when is_list(context), do: Map.new(context)
  defp context_map(context) when is_map(context), do: context

  defp fingerprint(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  rescue
    _exception -> nil
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      _other -> nil
    end
  end

  defp reason_text(reason) do
    reason
    |> inspect()
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, @max_message_length)
  end

  defp display_key(key) when is_binary(key), do: safe_destination(key)
  defp display_key(key), do: inspect(key)

  defp safe_destination(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_.:-]/, "?")
    |> String.slice(0, 80)
  end

  defp cap_diagnostics(diagnostics) do
    diagnostics
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.slice(to_string(&1), 0, @max_message_length))
    |> Enum.take(@max_diagnostics)
  end
end
