defmodule AllbertAssist.Intent.Eval.Corpus do
  @moduledoc """
  Data-only YAML corpus loader for the deterministic intent routing gate.

  The committed corpus is the only input accepted by CI/release gates. Runtime
  capture writes candidates elsewhere and a later reviewed add step promotes them
  into this shape.
  """

  defmodule Case do
    @moduledoc false
    @enforce_keys [:id, :domain, :surface, :utterance, :expected]
    defstruct id: nil,
              domain: nil,
              surface: :any,
              utterance: nil,
              context: %{},
              expected: %{kind: :none, slots: %{}},
              negative?: false,
              holdout?: false,
              rationale: nil,
              path: nil
  end

  @fixture_candidates [
    "apps/allbert_assist/test/fixtures/intent/eval",
    "test/fixtures/intent/eval"
  ]

  @valid_kinds ~w(execute clarify answer none)a
  @valid_surfaces ~w(any web tui telegram discord slack matrix whatsapp signal email)a

  @type t :: %Case{
          id: String.t(),
          domain: String.t(),
          surface: atom(),
          utterance: String.t(),
          context: map(),
          expected: map(),
          negative?: boolean(),
          holdout?: boolean(),
          rationale: String.t() | nil,
          path: String.t() | nil
        }

  @spec load(keyword() | String.t()) :: {:ok, [t()]} | {:error, term()}
  def load(opts \\ [])

  def load(path) when is_binary(path), do: load(path: path)

  def load(opts) when is_list(opts) do
    with {:ok, files} <- corpus_files(opts),
         {:ok, cases} <- read_files(files) do
      {:ok, Enum.sort_by(cases, & &1.id)}
    end
  end

  @spec validate(map()) :: {:ok, t()} | {:error, term()}
  def validate(attrs) when is_map(attrs), do: normalize_case(attrs, nil)

  def validate(other), do: {:error, {:expected_case_map, other}}

  defp corpus_files(opts) do
    roots =
      opts
      |> Keyword.get(:path, Keyword.get(opts, :fixture, default_root()))
      |> List.wrap()

    files =
      roots
      |> Enum.flat_map(&expand_path/1)
      |> Enum.uniq()
      |> Enum.sort()

    cond do
      files == [] ->
        {:error, {:no_corpus_files, roots}}

      Enum.any?(files, &(Path.extname(&1) not in [".yaml", ".yml"])) ->
        {:error, :unsafe_corpus_path}

      true ->
        {:ok, files}
    end
  end

  defp default_root do
    Enum.find(@fixture_candidates, &File.dir?/1) || hd(@fixture_candidates)
  end

  defp expand_path(path) do
    cond do
      File.dir?(path) ->
        Path.wildcard(Path.join(path, "**/*.yaml")) ++ Path.wildcard(Path.join(path, "**/*.yml"))

      File.regular?(path) ->
        [path]

      true ->
        []
    end
  end

  defp read_files(files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case read_file(file) do
        {:ok, cases} -> {:cont, {:ok, acc ++ cases}}
        {:error, reason} -> {:halt, {:error, {file, reason}}}
      end
    end)
  end

  defp read_file(file) do
    with {:ok, document} <- YamlElixir.read_from_file(file),
         {:ok, case_maps} <- extract_cases(document),
         {:ok, cases} <- normalize_cases(case_maps, file) do
      {:ok, cases}
    end
  end

  defp extract_cases(%{"cases" => cases}) when is_list(cases), do: {:ok, cases}
  defp extract_cases(%{cases: cases}) when is_list(cases), do: {:ok, cases}
  defp extract_cases(cases) when is_list(cases), do: {:ok, cases}
  defp extract_cases(case_map) when is_map(case_map), do: {:ok, [case_map]}
  defp extract_cases(other), do: {:error, {:expected_case_or_case_list, other}}

  defp normalize_cases(case_maps, path) do
    Enum.reduce_while(case_maps, {:ok, []}, fn attrs, {:ok, acc} ->
      case normalize_case(attrs, path) do
        {:ok, case} -> {:cont, {:ok, [case | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, cases} -> {:ok, Enum.reverse(cases)}
      error -> error
    end
  end

  defp normalize_case(attrs, path) when is_map(attrs) do
    attrs = atomize_known_keys(attrs)
    expected = atomize_known_keys(Map.get(attrs, :expected, %{}))

    with :ok <- validate_schema_version(attrs),
         {:ok, id} <- required_string(attrs, :id),
         {:ok, domain} <- required_domain(attrs),
         {:ok, utterance} <- required_string(attrs, :utterance),
         {:ok, surface} <- normalize_surface(Map.get(attrs, :surface, :any)),
         {:ok, expected} <- normalize_expected(expected) do
      {:ok,
       %Case{
         id: id,
         domain: domain,
         surface: surface,
         utterance: utterance,
         context: normalize_map(Map.get(attrs, :context, %{})),
         expected: expected,
         negative?: truthy?(Map.get(attrs, :negative, false)),
         holdout?: truthy?(Map.get(attrs, :holdout, false)),
         rationale: optional_string(Map.get(attrs, :rationale)),
         path: path
       }}
    end
  end

  defp normalize_case(other, _path), do: {:error, {:expected_case_map, other}}

  defp validate_schema_version(%{schema_version: version}) when version in [1, "1"], do: :ok

  defp validate_schema_version(%{schema_version: version}),
    do: {:error, {:invalid_schema_version, version}}

  defp validate_schema_version(_attrs), do: :ok

  defp required_domain(attrs) do
    case Map.get(attrs, :domain, Map.get(attrs, :category)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value -> {:error, {:invalid_domain, value}}
    end
  end

  defp required_string(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value -> {:error, {:invalid_string, key, value}}
    end
  end

  defp optional_string(nil), do: nil
  defp optional_string(value) when is_binary(value), do: value
  defp optional_string(value), do: to_string(value)

  defp normalize_surface(value) do
    surface = normalize_atom(value)

    if surface in @valid_surfaces do
      {:ok, surface}
    else
      {:error, {:invalid_surface, value}}
    end
  end

  defp normalize_expected(expected) when is_map(expected) do
    with {:ok, kind} <- normalize_kind(Map.get(expected, :kind)),
         {:ok, action} <- normalize_action(kind, Map.get(expected, :action)) do
      {:ok, %{kind: kind, action: action, slots: normalize_slots(Map.get(expected, :slots, %{}))}}
    end
  end

  defp normalize_expected(other), do: {:error, {:invalid_expected, other}}

  defp normalize_kind(value) do
    kind = normalize_atom(value)

    if kind in @valid_kinds do
      {:ok, kind}
    else
      {:error, {:invalid_expected_kind, value}}
    end
  end

  defp normalize_action(:execute, value) when is_binary(value) and value != "", do: {:ok, value}
  defp normalize_action(:execute, value), do: {:error, {:missing_expected_action, value}}
  defp normalize_action(_kind, nil), do: {:ok, nil}
  defp normalize_action(_kind, value) when is_binary(value), do: {:ok, value}
  defp normalize_action(_kind, value), do: {:ok, to_string(value)}

  defp normalize_slots(nil), do: %{}
  defp normalize_slots(slots) when is_map(slots), do: normalize_map(slots)

  defp normalize_slots(slots) when is_list(slots) do
    Map.new(slots, fn slot -> {to_string(slot), :present} end)
  end

  defp normalize_slots(_slots), do: %{}

  defp normalize_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_map(_other), do: %{}

  defp atomize_known_keys(map) do
    Map.new(map, fn {key, value} ->
      normalized_key =
        case key do
          key when is_atom(key) ->
            key

          key when is_binary(key) ->
            known_key(key)
        end

      {normalized_key, value}
    end)
  end

  defp known_key(key) do
    case String.replace(key, "-", "_") do
      "id" -> :id
      "schema_version" -> :schema_version
      "domain" -> :domain
      "category" -> :category
      "surface" -> :surface
      "utterance" -> :utterance
      "context" -> :context
      "expected" -> :expected
      "negative" -> :negative
      "holdout" -> :holdout
      "rationale" -> :rationale
      "kind" -> :kind
      "action" -> :action
      "slots" -> :slots
      other -> other
    end
  end

  defp normalize_atom(value) when is_atom(value), do: value

  defp normalize_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp normalize_atom(_value), do: nil

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false
end
