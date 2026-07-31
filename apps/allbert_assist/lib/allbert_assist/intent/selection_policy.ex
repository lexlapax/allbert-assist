defmodule AllbertAssist.Intent.SelectionPolicy do
  @moduledoc """
  Canonical acceptance policy for model- or ranker-proposed intents.

  A proposal carries no authority and its diagnostics are not trusted as the
  source of policy. This module resolves the active descriptor by action name,
  derives evidence from the operator's actual utterance, and fails closed when
  the descriptor cannot be resolved. Deterministic ladder routes remain
  compatible, while actions with explicit policy must satisfy that same policy
  regardless of which route proposed them.
  """

  alias AllbertAssist.Intent.Decision
  alias AllbertAssist.Intent.Descriptor
  alias AllbertAssist.Intent.Handoff
  alias AllbertAssist.Intent.Router.DescriptorResolver
  alias AllbertAssist.Runtime.SafeTerm

  @type result :: %{
          accepted?: boolean(),
          action_name: String.t() | nil,
          policy: atom(),
          evidence: map(),
          resolution: :resolved | :unresolved
        }

  @doc "Evaluate one proposed action against its canonical active descriptor."
  @spec evaluate(String.t(), String.t(), keyword()) :: result()
  def evaluate(action_name, text, opts \\ [])

  def evaluate(action_name, text, opts) when is_binary(action_name) and is_binary(text) do
    [action_name]
    |> evaluate_many(text, opts)
    |> Map.get(action_name, unresolved(action_name))
  rescue
    _exception -> unresolved(action_name)
  catch
    :exit, _reason -> unresolved(action_name)
  end

  def evaluate(action_name, _text, _opts), do: unresolved(normalize_action(action_name))

  @doc "Return whether an Engine decision may be consumed as an action proposal."
  @spec decision_accepted?(Decision.t(), String.t(), keyword()) :: boolean()
  def decision_accepted?(decision, text, opts \\ [])

  def decision_accepted?(
        %Decision{intent: :direct_answer, selected_action: "direct_answer"},
        text,
        _opts
      )
      when is_binary(text),
      do: true

  def decision_accepted?(%Decision{intent: :direct_answer}, text, _opts) when is_binary(text),
    do: false

  def decision_accepted?(%Decision{selected_action: action_name}, text, opts)
      when is_binary(action_name) and is_binary(text),
      do: evaluate(action_name, text, opts).accepted?

  def decision_accepted?(%Decision{} = decision, text, opts) when is_binary(text) do
    case Handoff.from_decision(decision) do
      {:ok, %Handoff{action_name: action_name}} ->
        evaluate(action_name, text, opts).accepted?

      {:error, _reason} ->
        not handoff_metadata?(decision)
    end
  rescue
    _exception -> false
  catch
    :exit, _reason -> false
  end

  def decision_accepted?(_decision, _text, _opts), do: false

  @doc "Apply explicit descriptor policy to a deterministic ladder action."
  @spec deterministic_action_accepted?(String.t(), String.t(), keyword()) :: boolean()
  def deterministic_action_accepted?(action_name, text, opts \\ [])

  def deterministic_action_accepted?(action_name, text, opts)
      when is_binary(action_name) and is_binary(text) and is_list(opts) do
    case evaluate(action_name, text, opts) do
      %{resolution: :resolved, policy: :explicit_evidence, accepted?: accepted?} ->
        accepted?

      %{resolution: :resolved, policy: :semantic} ->
        # A deterministic predicate is itself the route's evidence. The
        # descriptor-grounding requirement applies to model/ranker proposals;
        # only an explicitly stricter descriptor policy constrains the ladder.
        true

      %{resolution: :unresolved} ->
        # Deterministic routes predate descriptor coverage. Preserve a truly
        # ungoverned legacy route, but fail closed when an explicit policy exists
        # below an active disable/unavailability layer.
        action_name
        |> inherited_descriptor(opts)
        |> case do
          %Descriptor{selection_policy: :explicit_evidence} -> false
          _ungoverned_or_semantic -> true
        end
    end
  rescue
    _exception -> false
  catch
    :exit, _reason -> false
  end

  def deterministic_action_accepted?(_action_name, _text, _opts), do: false

  @doc "Evaluate several proposed actions against one descriptor and utterance snapshot."
  @spec evaluate_many(term(), String.t(), keyword()) :: %{optional(String.t()) => result()}
  def evaluate_many(action_names, text, opts \\ [])

  def evaluate_many(action_names, text, opts) when is_binary(text) and is_list(opts) do
    names =
      action_names
      |> SafeTerm.wrap_list()
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.uniq()

    descriptors =
      Keyword.get_lazy(opts, :descriptors, fn ->
        DescriptorResolver.resolve(Keyword.get(opts, :resolver_opts, []))
      end)

    descriptors_by_action =
      descriptors
      |> SafeTerm.wrap_list()
      |> Enum.flat_map(fn
        %Descriptor{action_name: action_name} = descriptor when is_binary(action_name) ->
          [{action_name, descriptor}]

        _other ->
          []
      end)
      |> Map.new()

    match_context = Descriptor.prepare_match_context(text)

    Map.new(names, fn action_name ->
      result =
        case Map.get(descriptors_by_action, action_name) do
          %Descriptor{} = descriptor ->
            resolved(action_name, descriptor, text, match_context)

          _missing ->
            unresolved(action_name)
        end

      {action_name, result}
    end)
  rescue
    _exception -> unresolved_many(action_names)
  catch
    :exit, _reason -> unresolved_many(action_names)
  end

  def evaluate_many(action_names, _text, _opts), do: unresolved_many(action_names)

  @doc "Return true only when every proposed action is canonically accepted."
  @spec accept_all?([String.t()], String.t(), keyword()) :: boolean()
  def accept_all?(action_names, text, opts \\ [])

  def accept_all?(action_names, text, opts) when is_list(action_names) and is_binary(text) do
    if proper_list?(action_names) and Enum.all?(action_names, &valid_action_name?/1) do
      names = Enum.uniq(action_names)
      results = evaluate_many(names, text, opts)

      names != [] and Enum.all?(names, &get_in(results, [&1, :accepted?]))
    else
      false
    end
  end

  def accept_all?(_action_names, _text, _opts), do: false

  @doc "Return the canonically grounded subset of a well-formed proposal list."
  @spec supported_action_names([String.t()], String.t(), keyword()) :: [String.t()]
  def supported_action_names(action_names, text, opts \\ [])

  def supported_action_names(action_names, text, opts)
      when is_list(action_names) and is_binary(text) and is_list(opts) do
    if proper_list?(action_names) and Enum.all?(action_names, &valid_action_name?/1) do
      names = Enum.uniq(action_names)
      descriptors = resolved_descriptors(opts)
      results = evaluate_many(names, text, Keyword.put(opts, :descriptors, descriptors))
      descriptors_by_action = descriptors_by_action(descriptors)
      match_context = Descriptor.prepare_match_context(text)

      Enum.filter(names, fn action_name ->
        get_in(results, [action_name, :accepted?]) ||
          clarification_supported?(
            Map.get(descriptors_by_action, action_name),
            match_context
          )
      end)
    else
      []
    end
  end

  def supported_action_names(_action_names, _text, _opts), do: []

  @doc "Strictly validate and reduce a clarification shortlist to grounded canonical options."
  @spec grounded_shortlist(term(), String.t(), keyword()) :: {:ok, [map()]} | :error
  def grounded_shortlist(shortlist, text, opts \\ [])

  def grounded_shortlist(shortlist, text, opts) when is_binary(text) and is_list(opts) do
    with {:ok, action_names} <- shortlist_action_names(shortlist),
         [_first | _rest] = supported <- supported_action_names(action_names, text, opts) do
      {:ok, supported_shortlist(shortlist, supported)}
    else
      _unsupported_or_malformed -> :error
    end
  end

  def grounded_shortlist(_shortlist, _text, _opts), do: :error

  @doc "Return true when a well-formed shortlist has at least one grounded action."
  @spec accept_any?([String.t()], String.t(), keyword()) :: boolean()
  def accept_any?(action_names, text, opts \\ [])

  def accept_any?(action_names, text, opts) when is_list(action_names) and is_binary(text) do
    supported_action_names(action_names, text, opts) != []
  end

  def accept_any?(_action_names, _text, _opts), do: false

  defp resolved(action_name, descriptor, text, match_context) do
    evidence = Descriptor.selection_evidence(descriptor, text, nil, match_context)
    policy = descriptor.selection_policy

    %{
      accepted?:
        Descriptor.selection_supported?(%{
          selection_policy: policy,
          selection_evidence: evidence
        }),
      action_name: action_name,
      policy: policy,
      evidence: evidence,
      resolution: :resolved
    }
  end

  defp unresolved_many(action_names) do
    action_names
    |> SafeTerm.wrap_list()
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Map.new(&{&1, unresolved(&1)})
  end

  defp unresolved(action_name) do
    %{
      accepted?: false,
      action_name: action_name,
      policy: :unresolved,
      evidence: %{satisfied?: false},
      resolution: :unresolved
    }
  end

  defp normalize_action(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_action(value) when is_binary(value), do: value
  defp normalize_action(_value), do: nil

  defp valid_action_name?(value), do: is_binary(value) and String.trim(value) != ""

  defp handoff_metadata?(%Decision{trace_metadata: metadata}) when is_map(metadata) do
    Map.has_key?(metadata, :intent_handoff) or Map.has_key?(metadata, "intent_handoff")
  end

  defp handoff_metadata?(_decision), do: false

  defp inherited_descriptor(action_name, opts) do
    descriptors =
      Keyword.get_lazy(opts, :inherited_descriptors, fn ->
        DescriptorResolver.resolve(ignore_disabled?: true)
      end)

    descriptors
    |> SafeTerm.wrap_list()
    |> Enum.find(fn
      %Descriptor{action_name: ^action_name} -> true
      _other -> false
    end)
  end

  defp resolved_descriptors(opts) do
    Keyword.get_lazy(opts, :descriptors, fn ->
      DescriptorResolver.resolve(Keyword.get(opts, :resolver_opts, []))
    end)
    |> SafeTerm.wrap_list()
  end

  defp descriptors_by_action(descriptors) do
    descriptors
    |> Enum.flat_map(fn
      %Descriptor{action_name: action_name} = descriptor when is_binary(action_name) ->
        [{action_name, descriptor}]

      _other ->
        []
    end)
    |> Map.new()
  end

  defp clarification_supported?(%Descriptor{} = descriptor, match_context),
    do: Descriptor.clarification_match_score(descriptor, match_context) > 0

  defp clarification_supported?(_descriptor, _match_context), do: false

  defp shortlist_action_names([]), do: {:ok, []}

  defp shortlist_action_names([item | tail]) when is_list(tail) do
    with {:ok, action_name} <- shortlist_action_name(item),
         {:ok, rest} <- shortlist_action_names(tail) do
      {:ok, [action_name | rest]}
    end
  end

  defp shortlist_action_names(_malformed), do: :error

  defp shortlist_action_name(%{action_name: action_name})
       when is_binary(action_name) and action_name != "",
       do: {:ok, action_name}

  defp shortlist_action_name(%{"action_name" => action_name})
       when is_binary(action_name) and action_name != "",
       do: {:ok, action_name}

  defp shortlist_action_name(_malformed), do: :error

  defp supported_shortlist(shortlist, supported) do
    Enum.flat_map(supported, fn action_name ->
      case Enum.find(shortlist, &(shortlist_action_name(&1) == {:ok, action_name})) do
        nil -> []
        item -> [item]
      end
    end)
  end

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_other), do: false
end
