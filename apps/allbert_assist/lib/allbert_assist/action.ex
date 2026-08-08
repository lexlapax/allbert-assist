defmodule AllbertAssist.Action do
  @moduledoc """
  Allbert-facing action DSL.

  Runtime-facing capability actions use this wrapper instead of calling
  `Jido.Action` directly. The wrapper keeps Jido as the action substrate while
  pinning Allbert-specific capability metadata on the module that owns the
  action. Metadata is descriptive only; Security Central remains the authority.
  """

  @capability_keys [
    :permission,
    :exposure,
    :execution_mode,
    :skill_backed?,
    :confirmation,
    :app_id,
    :plugin_id,
    :notes,
    :resumable?,
    :retry_safety
  ]
  @required_capability_keys [
    :permission,
    :exposure,
    :execution_mode,
    :skill_backed?,
    :confirmation
  ]

  @type capability_attrs :: %{
          required(:permission) => atom(),
          required(:exposure) => :agent | :internal,
          required(:execution_mode) => atom(),
          required(:skill_backed?) => boolean(),
          required(:confirmation) => atom(),
          optional(:app_id) => atom(),
          optional(:plugin_id) => String.t(),
          optional(:notes) => String.t(),
          optional(:resumable?) => boolean(),
          optional(:retry_safety) => :safe | :unsafe | :unknown
        }
  @type capability_key ::
          :permission
          | :exposure
          | :execution_mode
          | :skill_backed?
          | :confirmation
          | :app_id
          | :plugin_id
          | :notes
          | :resumable?
          | :retry_safety

  defmacro __using__(opts) do
    {registry_order, opts} = Keyword.pop(opts, :registry_order)
    registry_order = validate_registry_order!(registry_order)
    {capability_opts, jido_opts} = Keyword.split(opts, @capability_keys)
    capability_attrs = validate_capability!(capability_opts)

    quote bind_quoted: [
            capability_attrs: Macro.escape(capability_attrs),
            registry_order: registry_order,
            jido_opts: Macro.escape(jido_opts)
          ] do
      use Jido.Action, jido_opts

      @allbert_action_capability capability_attrs
      @allbert_action_registry_order registry_order

      @doc false
      def capability, do: @allbert_action_capability

      @doc false
      def allbert_action?, do: true

      @doc false
      def registry_order, do: @allbert_action_registry_order

      @doc false
      def response_completed(message, attrs \\ %{}),
        do: AllbertAssist.Runtime.Response.completed(message, attrs)

      @doc false
      def response_needs_confirmation(message, attrs \\ %{}),
        do: AllbertAssist.Runtime.Response.needs_confirmation(message, attrs)

      @doc false
      def response_denied(message, attrs \\ %{}),
        do: AllbertAssist.Runtime.Response.denied(message, attrs)

      @doc false
      def response_error(message, reason \\ nil, attrs \\ %{}),
        do: AllbertAssist.Runtime.Response.error(message, reason, attrs)

      @doc false
      def response_action(status, attrs \\ %{}),
        do: AllbertAssist.Runtime.Response.action(name(), status, attrs)

      @doc false
      def response_schema, do: AllbertAssist.Runtime.Response.action_response_schema()

      defoverridable capability: 0,
                     response_completed: 1,
                     response_completed: 2,
                     response_needs_confirmation: 1,
                     response_needs_confirmation: 2,
                     response_denied: 1,
                     response_denied: 2,
                     response_error: 1,
                     response_error: 2,
                     response_error: 3,
                     response_action: 1,
                     response_action: 2,
                     response_schema: 0
    end
  end

  @doc "Return the option keys owned by the Allbert action wrapper."
  @spec capability_keys() :: [capability_key(), ...]
  def capability_keys, do: @capability_keys

  @doc "Normalize and validate action capability metadata."
  @spec validate_capability(keyword() | map()) :: {:ok, capability_attrs()} | {:error, term()}
  def validate_capability(attrs) when is_list(attrs) do
    attrs
    |> Map.new()
    |> validate_capability()
  end

  def validate_capability(attrs) when is_map(attrs) do
    missing =
      @required_capability_keys
      |> Enum.reject(&Map.has_key?(attrs, &1))

    cond do
      missing != [] ->
        {:error, {:missing_capability_keys, missing}}

      Map.get(attrs, :exposure) not in [:agent, :internal] ->
        {:error, {:invalid_exposure, Map.get(attrs, :exposure)}}

      not is_boolean(Map.get(attrs, :skill_backed?)) ->
        {:error, {:invalid_skill_backed, Map.get(attrs, :skill_backed?)}}

      not atom?(Map.get(attrs, :permission)) ->
        {:error, {:invalid_permission, Map.get(attrs, :permission)}}

      not atom?(Map.get(attrs, :execution_mode)) ->
        {:error, {:invalid_execution_mode, Map.get(attrs, :execution_mode)}}

      not atom?(Map.get(attrs, :confirmation)) ->
        {:error, {:invalid_confirmation, Map.get(attrs, :confirmation)}}

      Map.get(attrs, :retry_safety, :unknown) not in [:safe, :unsafe, :unknown] ->
        {:error, {:invalid_retry_safety, Map.get(attrs, :retry_safety)}}

      true ->
        {:ok, normalize_capability(attrs)}
    end
  end

  def validate_capability(attrs), do: {:error, {:invalid_capability_attrs, attrs}}

  @doc "Normalize and validate action capability metadata, raising on invalid data."
  @spec validate_capability!(keyword() | map()) :: capability_attrs()
  def validate_capability!(attrs) do
    case validate_capability(attrs) do
      {:ok, attrs} ->
        attrs

      {:error, reason} ->
        raise ArgumentError, "invalid Allbert action capability: #{inspect(reason)}"
    end
  end

  @doc "Return true when a module was declared through `use AllbertAssist.Action`."
  @spec allbert_action?(module()) :: boolean()
  def allbert_action?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :allbert_action?, 0) and
      module.allbert_action?() == true
  rescue
    _exception -> false
  end

  def allbert_action?(_module), do: false

  defp normalize_capability(attrs) do
    attrs
    |> Map.take(@capability_keys)
    |> Map.put_new(:resumable?, false)
    |> Map.put_new(:retry_safety, :unknown)
  end

  defp validate_registry_order!(nil), do: nil

  defp validate_registry_order!(value) when is_integer(value) and value >= 0, do: value

  defp validate_registry_order!(value) do
    raise ArgumentError, "invalid Allbert action registry_order: #{inspect(value)}"
  end

  defp atom?(value), do: is_atom(value) and not is_nil(value)
end
