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
    :resumable?
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
          optional(:resumable?) => boolean()
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

  defmacro __using__(opts) do
    {capability_opts, jido_opts} = Keyword.split(opts, @capability_keys)
    capability_attrs = validate_capability!(capability_opts)

    quote bind_quoted: [
            capability_attrs: Macro.escape(capability_attrs),
            jido_opts: Macro.escape(jido_opts)
          ] do
      use Jido.Action, jido_opts

      @allbert_action_capability capability_attrs

      @doc false
      def capability, do: @allbert_action_capability

      @doc false
      def allbert_action?, do: true

      defoverridable capability: 0
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
  end

  defp atom?(value), do: is_atom(value) and not is_nil(value)
end
