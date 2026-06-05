defmodule AllbertAssist.SelfImprovement.TraceIndex do
  @moduledoc """
  Read-only compiled view over trace memory for self-improvement discovery.

  The index is computed on demand from existing trace markdown under
  `<ALLBERT_HOME>/memory/traces/`. It persists nothing, grants no authority,
  and returns only redacted samples plus trace reference pointers.
  """

  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings

  @type query_filter :: map() | keyword()
  @type pattern_type :: :action_chain | :correction | :failed_intent | :repeated_prompt
  @type pattern :: %{
          required(:pattern_type) => pattern_type(),
          required(:fingerprint) => String.t(),
          required(:count) => non_neg_integer(),
          required(:sample) => String.t() | nil,
          required(:summary) => String.t(),
          required(:source_refs) => [map()],
          optional(:actions) => [String.t()],
          optional(:scope) => map(),
          optional(:status) => String.t()
        }
  @type index :: %{
          required(:enabled?) => boolean(),
          required(:entries_scanned) => non_neg_integer(),
          required(:patterns) => [pattern()],
          required(:diagnostics) => [map()]
        }

  @failed_statuses ~w(denied failed error unsupported needs_confirmation)
  @secret_ref "[SECRET_REF]"
  @correction_phrases [
    "actually",
    "correction",
    "fix that",
    "not what",
    "try again",
    "wrong"
  ]
  @source_ref_limit 10

  @spec index(query_filter()) :: {:ok, index()}
  def index(filter \\ %{}) do
    filter = normalize_filter(filter)

    with {:enabled?, true, diagnostics} <- enabled_state() do
      max_entries = setting_value("self_improvement.trace_index.max_indexed_entries", 5000)
      min_repetitions = setting_value("self_improvement.trace_index.min_repetitions", 3)
      trace_root = Path.join(Paths.memory_root(), "traces")

      {entries, read_diagnostics} =
        trace_root
        |> trace_files(max_entries)
        |> read_entries(trace_root)

      patterns =
        entries
        |> scoped_entries(filter)
        |> build_patterns(min_repetitions)
        |> filter_patterns(filter)

      {:ok,
       %{
         enabled?: true,
         entries_scanned: length(entries),
         patterns: patterns,
         diagnostics: diagnostics ++ trace_root_diagnostics(trace_root) ++ read_diagnostics
       }}
    else
      {:enabled?, false, diagnostics} ->
        {:ok, %{enabled?: false, entries_scanned: 0, patterns: [], diagnostics: diagnostics}}
    end
  end

  @spec query(query_filter()) :: {:ok, [pattern()]}
  def query(filter \\ %{}) do
    with {:ok, %{patterns: patterns}} <- index(filter) do
      {:ok, patterns}
    end
  end

  defp enabled_state do
    self_improvement_enabled? = setting_value("self_improvement.enabled", false)
    trace_index_enabled? = setting_value("self_improvement.trace_index.enabled", false)

    diagnostics =
      []
      |> maybe_disabled_diagnostic(self_improvement_enabled?, :self_improvement_disabled)
      |> maybe_disabled_diagnostic(trace_index_enabled?, :trace_index_disabled)

    {:enabled?, self_improvement_enabled? and trace_index_enabled?, diagnostics}
  end

  defp maybe_disabled_diagnostic(diagnostics, true, _reason), do: diagnostics

  defp maybe_disabled_diagnostic(diagnostics, false, reason) do
    [%{status: :disabled, reason: reason} | diagnostics]
  end

  defp setting_value(key, default) do
    case Settings.get(key) do
      {:ok, value} -> value
      _other -> default
    end
  rescue
    _exception -> default
  end

  defp trace_files(trace_root, max_entries) do
    if File.dir?(trace_root) do
      trace_root
      |> Path.join("**/*.md")
      |> Path.wildcard()
      |> Enum.sort(:desc)
      |> Enum.take(max_entries)
    else
      []
    end
  end

  defp trace_root_diagnostics(trace_root) do
    if File.dir?(trace_root), do: [], else: [%{status: :skipped, reason: :missing_trace_root}]
  end

  defp read_entries(paths, trace_root) do
    Enum.reduce(paths, {[], []}, fn path, {entries, diagnostics} ->
      case File.read(path) do
        {:ok, content} ->
          {[parse_entry(path, trace_root, content) | entries], diagnostics}

        {:error, reason} ->
          {entries,
           [%{status: :skipped, path: source_ref(path, trace_root), reason: reason} | diagnostics]}
      end
    end)
    |> then(fn {entries, diagnostics} -> {Enum.reverse(entries), Enum.reverse(diagnostics)} end)
  end

  defp parse_entry(path, trace_root, content) do
    metadata = metadata(content)
    prompt = content |> section("Input") |> redact_string()
    selected_action = metadata_value(metadata, "selected_action") || "none"
    action_chain = action_chain(content, selected_action)
    status = metadata_value(metadata, "status") || "unknown"

    %{
      source_ref: source_ref(path, trace_root),
      user_id: metadata_value(metadata, "user"),
      app_id: metadata_value(metadata, "active_app"),
      status: status,
      selected_action: selected_action,
      prompt: prompt,
      prompt_fingerprint: normalize_text(prompt),
      action_chain: action_chain,
      correction?: correction_prompt?(prompt),
      failed_intent?: failed_intent?(status, selected_action)
    }
  end

  defp metadata(content) do
    ~r/^- ([^:\n]+):\s*(.*)$/m
    |> Regex.scan(content)
    |> Map.new(fn [_line, key, value] ->
      {
        key
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9]+/, "_")
        |> String.trim("_"),
        String.trim(value)
      }
    end)
  end

  defp metadata_value(metadata, key), do: Map.get(metadata, key) |> blank_to_nil()

  defp section(content, title) do
    pattern = Regex.compile!("^## #{Regex.escape(title)}\\s*\\n(?<body>.*?)(?=^## |\\z)", "ms")

    case Regex.named_captures(pattern, content) do
      %{"body" => body} -> String.trim(body)
      _none -> ""
    end
  end

  defp action_chain(content, selected_action) do
    content
    |> section("Actions")
    |> action_names()
    |> fallback_action(selected_action)
  end

  defp action_names(actions_section) do
    [
      ~r/(?:^|[{\s])name:\s*"([^"]+)"/m,
      ~r/(?:^|[{\s])name:\s*([A-Za-z0-9_.:-]+)/m,
      ~r/"name"\s*=>\s*"([^"]+)"/m
    ]
    |> Enum.flat_map(&Regex.scan(&1, actions_section, capture: :all_but_first))
    |> List.flatten()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 in ["", "none"]))
    |> Enum.uniq()
  end

  defp fallback_action([], action) when is_binary(action) and action not in ["", "none"],
    do: [action]

  defp fallback_action(actions, _selected_action), do: actions

  defp correction_prompt?(prompt) do
    prompt = String.downcase(prompt)
    Enum.any?(@correction_phrases, &String.contains?(prompt, &1))
  end

  defp failed_intent?(status, selected_action) do
    status = status |> to_string() |> String.downcase()
    selected_action = selected_action |> to_string() |> String.downcase()

    status in @failed_statuses or selected_action in ["none", "unsupported_resource_workflow"]
  end

  defp scoped_entries(entries, filter) do
    user_id = filter_value(filter, "user_id")
    app_id = filter_value(filter, "app_id")

    Enum.filter(entries, fn entry ->
      (is_nil(user_id) or entry.user_id == user_id) and
        (is_nil(app_id) or entry.app_id == app_id)
    end)
  end

  defp build_patterns(entries, min_repetitions) do
    entries
    |> repeated_prompt_patterns(min_repetitions)
    |> Kernel.++(action_chain_patterns(entries, min_repetitions))
    |> Kernel.++(correction_patterns(entries, min_repetitions))
    |> Kernel.++(failed_intent_patterns(entries, min_repetitions))
    |> Enum.sort_by(fn pattern ->
      {-pattern.count, to_string(pattern.pattern_type), pattern.fingerprint}
    end)
  end

  defp repeated_prompt_patterns(entries, min_repetitions) do
    entries
    |> Enum.reject(&(&1.prompt_fingerprint == ""))
    |> Enum.group_by(& &1.prompt_fingerprint)
    |> repeated_groups(min_repetitions)
    |> Enum.map(fn {fingerprint, group} ->
      sample = group |> hd() |> Map.fetch!(:prompt)

      pattern(:repeated_prompt, fingerprint, group, %{
        sample: sample,
        summary: "Repeated prompt observed #{length(group)} times"
      })
    end)
  end

  defp action_chain_patterns(entries, min_repetitions) do
    entries
    |> Enum.reject(&Enum.empty?(&1.action_chain))
    |> Enum.group_by(&Enum.join(&1.action_chain, " > "))
    |> repeated_groups(min_repetitions)
    |> Enum.map(fn {fingerprint, group} ->
      actions = group |> hd() |> Map.fetch!(:action_chain)

      pattern(:action_chain, fingerprint, group, %{
        actions: actions,
        sample: nil,
        summary: "Repeated action chain observed #{length(group)} times"
      })
    end)
  end

  defp correction_patterns(entries, min_repetitions) do
    entries
    |> Enum.filter(& &1.correction?)
    |> Enum.reject(&(&1.prompt_fingerprint == ""))
    |> Enum.group_by(& &1.prompt_fingerprint)
    |> repeated_groups(min_repetitions)
    |> Enum.map(fn {fingerprint, group} ->
      sample = group |> hd() |> Map.fetch!(:prompt)

      pattern(:correction, fingerprint, group, %{
        sample: sample,
        summary: "Repeated correction prompt observed #{length(group)} times"
      })
    end)
  end

  defp failed_intent_patterns(entries, min_repetitions) do
    entries
    |> Enum.filter(& &1.failed_intent?)
    |> Enum.group_by(&failed_intent_fingerprint/1)
    |> repeated_groups(min_repetitions)
    |> Enum.map(fn {fingerprint, group} ->
      first = hd(group)

      pattern(:failed_intent, fingerprint, group, %{
        sample: first.prompt,
        status: first.status,
        summary: "Repeated failed intent observed #{length(group)} times"
      })
    end)
  end

  defp repeated_groups(groups, min_repetitions) do
    groups
    |> Enum.filter(fn {_fingerprint, group} -> length(group) >= min_repetitions end)
    |> Enum.sort_by(fn {fingerprint, group} -> {-length(group), fingerprint} end)
  end

  defp pattern(type, fingerprint, group, attrs) do
    Map.merge(
      %{
        pattern_type: type,
        fingerprint: fingerprint,
        count: length(group),
        source_refs: source_refs(group),
        scope: scope(group)
      },
      attrs
    )
  end

  defp source_refs(group) do
    group
    |> Enum.map(fn entry ->
      %{
        path: entry.source_ref,
        user_id: entry.user_id,
        app_id: entry.app_id
      }
    end)
    |> Enum.take(@source_ref_limit)
  end

  defp source_ref(path, trace_root) do
    path
    |> Path.relative_to(trace_root)
    |> then(&Path.join("traces", &1))
  end

  defp scope(group) do
    %{
      user_ids: group |> Enum.map(& &1.user_id) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      app_ids: group |> Enum.map(& &1.app_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    }
  end

  defp failed_intent_fingerprint(entry) do
    [entry.status, entry.selected_action]
    |> Enum.map(&normalize_text/1)
    |> Enum.join(":")
  end

  defp filter_patterns(patterns, filter) do
    pattern_type = filter_value(filter, "pattern_type") |> normalize_pattern_type()
    limit = filter_value(filter, "limit")

    patterns
    |> Enum.filter(fn pattern -> is_nil(pattern_type) or pattern.pattern_type == pattern_type end)
    |> maybe_limit(limit)
  end

  defp maybe_limit(patterns, limit) when is_integer(limit) and limit >= 0,
    do: Enum.take(patterns, limit)

  defp maybe_limit(patterns, _limit), do: patterns

  defp normalize_pattern_type(nil), do: nil

  defp normalize_pattern_type(type) when is_atom(type) do
    if type in [:repeated_prompt, :action_chain, :correction, :failed_intent], do: type
  end

  defp normalize_pattern_type(type) when is_binary(type) do
    type
    |> String.downcase()
    |> case do
      "repeated_prompt" -> :repeated_prompt
      "action_chain" -> :action_chain
      "correction" -> :correction
      "failed_intent" -> :failed_intent
      _other -> nil
    end
  end

  defp normalize_pattern_type(_type), do: nil

  defp normalize_filter(filter) when is_list(filter), do: Map.new(filter)
  defp normalize_filter(filter) when is_map(filter), do: filter
  defp normalize_filter(_filter), do: %{}

  defp filter_value(filter, key) do
    Map.get(filter, key) || Map.get(filter, String.to_atom(key))
  end

  defp redact_string(value) when is_binary(value) do
    value
    |> Redactor.redact()
    |> redact_embedded_secret_refs()
  end

  defp redact_string(_value), do: ""

  defp redact_embedded_secret_refs(value) do
    Regex.replace(~r/secret:\/\/[^\s\]\)\},]+/, value, @secret_ref)
  end

  defp normalize_text(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
