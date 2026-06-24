defmodule AllbertAssist.Coding.Search do
  @moduledoc """
  Bounded, cwd-jailed grep/glob helpers for the v0.57 coding tools.
  """

  alias AllbertAssist.Coding.Config
  alias AllbertAssist.Coding.PathPolicy
  alias AllbertAssist.Runtime.Redactor

  @ignore_files [gitignore: ".gitignore", allbertignore: ".allbertignore"]

  @doc "Search text files under an optional path inside the cwd jail."
  @spec grep(term(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def grep(pattern, context \\ %{}, opts \\ []) do
    with {:ok, pattern} <- normalize_pattern(pattern),
         {:ok, matcher} <- build_matcher(pattern, opts),
         {:ok, root} <- PathPolicy.resolve_dir(Keyword.get(opts, :path, "."), context),
         {:ok, jail} <- PathPolicy.jail(context) do
      rules = ignore_rules(jail)
      files = list_files(root.path, jail, rules)
      max_results = max_results(opts)
      max_output_bytes = max_output_bytes(opts)
      {matches, truncated?} = collect_grep_matches(files, matcher, max_results, max_output_bytes)

      {:ok,
       %{
         pattern: pattern,
         root: root.relative_path,
         matches: matches,
         match_count: length(matches),
         searched_file_count: length(files),
         truncated?: truncated?
       }}
    end
  end

  @doc "Expand a glob pattern inside the cwd jail."
  @spec glob(term(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def glob(pattern, context \\ %{}, opts \\ []) do
    with {:ok, pattern} <- normalize_glob(pattern),
         {:ok, jail} <- PathPolicy.jail(context) do
      rules = ignore_rules(jail)
      max_results = max_results(opts)

      matches =
        jail
        |> Path.join(pattern)
        |> Path.wildcard()
        |> Enum.sort()
        |> Enum.flat_map(&glob_entry(&1, jail, rules))
        |> Enum.take(max_results + 1)

      {bounded, truncated?} =
        if length(matches) > max_results do
          {Enum.take(matches, max_results), true}
        else
          {matches, false}
        end

      {:ok,
       %{
         pattern: pattern,
         matches: bounded,
         match_count: length(bounded),
         truncated?: truncated?
       }}
    end
  end

  @doc "Render grep matches with the configured output cap."
  @spec render_grep(map(), keyword()) :: {String.t(), boolean()}
  def render_grep(result, opts \\ []) do
    result.matches
    |> Enum.map(&"#{&1.path}:#{&1.line}: #{&1.text}")
    |> render_lines(Keyword.get(opts, :max_output_bytes, Config.search_max_output_bytes()))
  end

  @doc "Render glob matches with the configured output cap."
  @spec render_glob(map(), keyword()) :: {String.t(), boolean()}
  def render_glob(result, opts \\ []) do
    result.matches
    |> Enum.map(&"#{&1.path} #{&1.type} #{&1.byte_size || 0}b")
    |> render_lines(Keyword.get(opts, :max_output_bytes, Config.search_max_output_bytes()))
  end

  defp normalize_pattern(pattern) when is_binary(pattern) do
    pattern = String.trim(pattern)
    if pattern == "", do: {:error, :empty_pattern}, else: {:ok, pattern}
  end

  defp normalize_pattern(_pattern), do: {:error, :invalid_pattern}

  defp normalize_glob(pattern) when is_binary(pattern) do
    pattern = String.trim(pattern)

    cond do
      pattern == "" -> {:error, :empty_pattern}
      Path.type(pattern) == :absolute -> {:error, :absolute_glob_not_allowed}
      ".." in Path.split(pattern) -> {:error, :glob_path_escape}
      true -> {:ok, pattern}
    end
  end

  defp normalize_glob(_pattern), do: {:error, :invalid_pattern}

  defp build_matcher(pattern, opts) do
    regex? = Keyword.get(opts, :regex?, false)
    case_sensitive? = Keyword.get(opts, :case_sensitive?, true)

    cond do
      regex? ->
        compile_regex(pattern, case_sensitive?)

      case_sensitive? ->
        {:ok, fn line -> String.contains?(line, pattern) end}

      true ->
        downcased = String.downcase(pattern)
        {:ok, fn line -> String.contains?(String.downcase(line), downcased) end}
    end
  end

  defp compile_regex(pattern, true), do: Regex.compile(pattern)
  defp compile_regex(pattern, false), do: Regex.compile(pattern, "i")

  defp list_files(root, jail, rules) do
    root
    |> do_list_files(jail, rules)
    |> Enum.sort_by(& &1.relative_path)
  end

  defp do_list_files(root, jail, rules) do
    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.flat_map(&list_child(&1, root, jail, rules))

      {:error, _reason} ->
        []
    end
  end

  defp list_child(name, root, jail, rules) do
    path = Path.join(root, name)
    relative = PathPolicy.relative_path(path, jail)

    if ignored?(relative, rules), do: [], else: file_or_descend(path, jail, rules)
  end

  defp file_or_descend(path, jail, rules) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        [file_entry(path, jail)]

      {:ok, %{type: :directory}} ->
        do_list_files(path, jail, rules)

      {:ok, %{type: :symlink}} ->
        case PathPolicy.resolve_file(path, %{cwd_jail: jail}) do
          {:ok, file} -> [file]
          {:error, _reason} -> []
        end

      _other ->
        []
    end
  end

  defp file_entry(path, jail) do
    size =
      case File.stat(path) do
        {:ok, stat} -> stat.size
        {:error, _reason} -> 0
      end

    %{path: path, relative_path: PathPolicy.relative_path(path, jail), byte_size: size}
  end

  defp grep_file(file, matcher, remaining, remaining_bytes) do
    if binary_file?(file.path) do
      {:skip, :binary_file}
    else
      grep_text_file(file, matcher, remaining, remaining_bytes)
    end
  rescue
    _exception -> {:skip, :read_failed}
  end

  defp collect_grep_matches(files, matcher, max_results, max_output_bytes) do
    Enum.reduce_while(files, {[], false}, fn file, {matches, _truncated?} ->
      collect_grep_file(file, matches, matcher, max_results, max_output_bytes)
    end)
  end

  defp collect_grep_file(_file, matches, _matcher, max_results, _max_output_bytes)
       when length(matches) >= max_results do
    {:halt, {matches, true}}
  end

  defp collect_grep_file(file, matches, matcher, max_results, max_output_bytes) do
    remaining = max_results - length(matches)
    remaining_bytes = max_output_bytes - rendered_bytes(matches)

    case grep_file(file, matcher, remaining, remaining_bytes) do
      {:ok, file_matches, file_truncated?} ->
        collect_grep_file_matches(
          matches,
          file_matches,
          file_truncated?,
          max_results,
          max_output_bytes
        )

      {:skip, _reason} ->
        {:cont, {matches, false}}
    end
  end

  defp collect_grep_file_matches(
         matches,
         file_matches,
         file_truncated?,
         max_results,
         max_output_bytes
       ) do
    updated = matches ++ file_matches

    if file_truncated? or length(updated) >= max_results or
         rendered_bytes(updated) >= max_output_bytes do
      {:halt, {updated, true}}
    else
      {:cont, {updated, false}}
    end
  end

  defp grep_text_file(file, matcher, remaining, remaining_bytes) do
    file.path
    |> File.stream!(:line, [])
    |> Stream.with_index(1)
    |> Enum.reduce_while({[], false, 0}, fn line, state ->
      grep_line(line, state, file, matcher, remaining, remaining_bytes)
    end)
    |> case do
      {matches, truncated?, _bytes} -> {:ok, matches, truncated?}
    end
  end

  defp grep_line(
         {line, line_number},
         {matches, _truncated?, bytes},
         file,
         matcher,
         remaining,
         remaining_bytes
       ) do
    cond do
      length(matches) >= remaining ->
        {:halt, {matches, true, bytes}}

      matcher.(line) ->
        append_grep_match(line, line_number, matches, bytes, file, remaining_bytes)

      true ->
        {:cont, {matches, false, bytes}}
    end
  end

  defp append_grep_match(line, line_number, matches, bytes, file, remaining_bytes) do
    text = line |> String.trim_trailing() |> Redactor.redact()
    entry = %{path: file.relative_path, line: line_number, text: text}
    entry_bytes = byte_size("#{entry.path}:#{entry.line}: #{entry.text}\n")

    if bytes + entry_bytes > remaining_bytes do
      {:halt, {matches, true, bytes}}
    else
      {:cont, {matches ++ [entry], false, bytes + entry_bytes}}
    end
  end

  defp glob_entry(path, jail, rules) do
    relative = PathPolicy.relative_path(path, jail)

    cond do
      ignored?(relative, rules) ->
        []

      not PathPolicy.inside_jail?(path, jail) ->
        []

      true ->
        case File.stat(path) do
          {:ok, stat} when stat.type in [:regular, :directory] ->
            [
              %{
                path: relative,
                type: stat.type,
                byte_size: if(stat.type == :regular, do: stat.size)
              }
            ]

          _other ->
            []
        end
    end
  end

  defp binary_file?(path) do
    case File.open(path, [:read, :binary], fn io -> IO.binread(io, 4_096) end) do
      {:ok, sample} when is_binary(sample) -> :binary.match(sample, <<0>>) != :nomatch
      _other -> true
    end
  end

  defp ignore_rules(jail) do
    @ignore_files
    |> Enum.flat_map(fn
      {:gitignore, file} ->
        if Config.respect_gitignore?(), do: read_ignore_file(jail, file), else: []

      {:allbertignore, file} ->
        if Config.respect_allbertignore?(), do: read_ignore_file(jail, file), else: []
    end)
  end

  defp read_ignore_file(jail, file) do
    path = Path.join(jail, file)

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(
          &(&1 == "" or String.starts_with?(&1, "#") or String.starts_with?(&1, "!"))
        )

      {:error, _reason} ->
        []
    end
  end

  defp ignored?("", _rules), do: false

  defp ignored?(relative, rules) do
    ".git" in Path.split(relative) or Enum.any?(rules, &ignore_rule_matches?(&1, relative))
  end

  defp ignore_rule_matches?(rule, relative) do
    rule = String.trim_leading(rule, "/")

    cond do
      String.ends_with?(rule, "/") ->
        prefix = String.trim_trailing(rule, "/")
        relative == prefix or String.starts_with?(relative, prefix <> "/")

      String.contains?(rule, "/") ->
        wildcard_match?(rule, relative)

      true ->
        Enum.any?(Path.split(relative), &wildcard_match?(rule, &1))
    end
  end

  defp wildcard_match?(pattern, value) do
    escaped =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    Regex.match?(Regex.compile!("^" <> escaped <> "$"), value)
  end

  defp max_results(opts) do
    case Keyword.get(opts, :max_results, Config.search_max_results()) do
      value when is_integer(value) and value > 0 -> value
      _other -> Config.search_max_results()
    end
  end

  defp max_output_bytes(opts) do
    case Keyword.get(opts, :max_output_bytes, Config.search_max_output_bytes()) do
      value when is_integer(value) and value > 0 -> value
      _other -> Config.search_max_output_bytes()
    end
  end

  defp render_lines(lines, max_bytes) do
    {rendered, truncated?, _bytes} =
      Enum.reduce_while(lines, {[], false, 0}, fn line, {acc, _truncated?, bytes} ->
        line = Redactor.redact(line)
        line_bytes = byte_size(line) + 1

        if bytes + line_bytes > max_bytes do
          {:halt, {acc, true, bytes}}
        else
          {:cont, {[line | acc], false, bytes + line_bytes}}
        end
      end)

    {rendered |> Enum.reverse() |> Enum.join("\n"), truncated?}
  end

  defp rendered_bytes(matches) do
    Enum.reduce(matches, 0, fn match, bytes ->
      bytes + byte_size("#{match.path}:#{match.line}: #{match.text}\n")
    end)
  end
end
