defmodule AllbertAssist.Intent.Router.ClarifyResolver do
  @moduledoc """
  Resolve a follow-up reply against the options offered by a prior clarification
  (ADR 0034 / ADR 0060). Deterministic and conservative: it binds only on a clear
  ordinal ("the second one"), a "yes"-style confirmation of a single option, or a
  distinctive label/action-name match. Anything ambiguous returns `:no_match`, so
  the turn is re-classified fresh (never a silent wrong selection). The chosen
  option still came from the offered, registry-validated shortlist.
  """
  @type option :: %{
          required(:kind) => atom() | String.t(),
          required(:id) => String.t(),
          optional(any()) => any()
        }

  @ordinals %{
    "first" => 0,
    "1" => 0,
    "one" => 0,
    "1st" => 0,
    "second" => 1,
    "2" => 1,
    "two" => 1,
    "2nd" => 1,
    "third" => 2,
    "3" => 2,
    "three" => 2,
    "3rd" => 2,
    "fourth" => 3,
    "4" => 3,
    "four" => 3,
    "4th" => 3,
    "fifth" => 4,
    "5" => 4,
    "five" => 4,
    "5th" => 4
  }
  @affirmatives ~w(yes yeah yep yup ok okay sure please do go)

  @spec resolve(String.t(), [option()]) :: {:ok, option()} | :no_match
  def resolve(_text, []), do: :no_match

  def resolve(text, options) when is_binary(text) and is_list(options) do
    tokens = tokenize(text)

    cond do
      (idx = ordinal_index(tokens)) && idx < length(options) -> {:ok, Enum.at(options, idx)}
      affirmative_single?(tokens, options) -> {:ok, hd(options)}
      opt = label_match(tokens, options) -> {:ok, opt}
      true -> :no_match
    end
  end

  def resolve(_text, _options), do: :no_match

  defp tokenize(text) do
    text |> String.downcase() |> String.split(~r/[^a-z0-9]+/u, trim: true)
  end

  defp ordinal_index(tokens), do: Enum.find_value(tokens, &Map.get(@ordinals, &1))

  defp affirmative_single?(tokens, options) do
    length(options) == 1 and Enum.any?(tokens, &(&1 in @affirmatives))
  end

  defp label_match(tokens, options) do
    token_set = MapSet.new(tokens)

    Enum.find(options, fn option ->
      option
      |> option_keywords()
      |> Enum.any?(&MapSet.member?(token_set, &1))
    end)
  end

  defp option_keywords(option) do
    id = option |> Map.get(:id) |> to_string()
    label = option |> Map.get(:label, "") |> to_string()

    (String.split(id, ~r/[^a-z0-9]+/i, trim: true) ++
       String.split(label, ~r/[^a-zA-Z0-9]+/, trim: true))
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(&1 in ~w(the a an to of and or note notes)))
    |> Enum.uniq()
  end
end
