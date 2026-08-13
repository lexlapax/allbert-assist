defmodule AllbertAssist.Credo.Check.PackOwnsItsApplicationEnv do
  @moduledoc false

  # v1.4 M13.3. An application's `lib/` may read its OWN application environment
  # and no other first-party application's.
  #
  # Why this check exists, and why nothing else catches it: extraction moves
  # code, not namespaces. Every pack M9/M12/M13 extracted kept its
  # test-injection seams pointed at `:allbert_assist` -- fourteen sites across
  # eight packs, each a pack reading the residual's configuration at runtime.
  #
  # No existing gate saw it. It is not a compile-time dependency, so the R0
  # acyclic-DAG proof passes and the ADR 0098 tier model looks clean. Dialyzer
  # cannot see it either, because `Application.get_env/3` returns `term()`, so
  # there is no type-level shadow of the kind M13.3 removed elsewhere.
  # `SettingsCentralNoBypass` caught exactly one of the fourteen, and that one
  # sat inside a 1,640-finding frozen inventory, indistinguishable from an alias
  # suggestion.
  #
  # The cause recurs at every extraction and every new pack, which is why this
  # is a check rather than a one-time cleanup: 1.5's `allbert_knowledge`, 1.6's
  # ingest substrate, and 1.7's `allbert_oauth`/`allbert_mcp` are all authored
  # against whatever v1.4 leaves enforced.

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [
      # "<owner>:<application>" pairs that may cross, each with a stated reason.
      # Keep this list short enough to read; an entry is a boundary exception.
      allowed_crossings: [
        # Test-only seams inside `if Mix.env() == :test` -- they do not exist in
        # a shipped build. Listed rather than special-cased because a check that
        # tries to interpret compile-time conditionals is a check nobody trusts.
        "allbert_assist:allbert_assist_web"
      ]
    ],
    explanations: [
      check: """
      An application must read its own application environment, not another
      first-party application's.

      Reading `Application.get_env(:allbert_assist, ...)` from inside a pack is a
      runtime dependency on the residual's namespace. It does not appear in the
      dependency DAG, so no compile-time gate rejects it, and it survives every
      proof that the boundary holds.

      Move the key to the reading application's own namespace.
      """
    ]

  alias Credo.Check.Params
  alias Credo.IssueMeta
  alias Credo.SourceFile

  @env_calls ~w[get_env fetch_env fetch_env! put_env delete_env]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    case owner(source_file.filename) do
      nil ->
        []

      owner ->
        issue_meta = IssueMeta.for(source_file, params)
        allowed = Params.get(params, :allowed_crossings, __MODULE__)

        source_file
        |> SourceFile.lines()
        |> Enum.flat_map(&issues_for_line(&1, owner, allowed, issue_meta))
    end
  end

  # Only an application's own `lib/` is in scope. `test/` legitimately reaches
  # across to set up another application, and config/ is not application code.
  defp owner(filename) do
    case Regex.run(~r"(?:^|/)apps/([a-z_0-9]+)/lib/", filename) do
      [_match, owner] -> owner
      _none -> nil
    end
  end

  defp issues_for_line({line_no, line}, owner, allowed, issue_meta) do
    ~r/Application\.(#{Enum.join(@env_calls, "|")})\(:([a-z_0-9]+)/
    |> Regex.scan(line)
    |> Enum.filter(fn [_match, _call, application] ->
      first_party?(application) and application != owner and
        "#{owner}:#{application}" not in allowed
    end)
    |> Enum.map(fn [_match, _call, application] ->
      format_issue(issue_meta,
        message:
          "`#{owner}` reads `:#{application}`'s application environment. " <>
            "Move the key into `:#{owner}` -- a pack must not depend on another " <>
            "application's namespace at runtime.",
        line_no: line_no,
        trigger: ":#{application}"
      )
    end)
  end

  defp first_party?("stocksage"), do: true
  defp first_party?(application), do: String.starts_with?(application, "allbert")
end
