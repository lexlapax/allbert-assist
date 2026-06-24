defmodule AllbertAssist.Coding.Prompt do
  @moduledoc """
  Compact Pi-mode prompt and six-tool surface definition.

  This module does not call models or grant authority. It only describes the
  session-local prompt bundle that a coding model boundary can use.
  """

  alias AllbertAssist.Coding.Config

  @tool_definitions [
    %{
      name: "read",
      permission: ":coding_file_read",
      description: "Read a bounded file chunk inside the pinned cwd jail.",
      args: "path, offset, limit, max_bytes"
    },
    %{
      name: "grep",
      permission: ":coding_file_read",
      description: "Search text inside the pinned cwd jail with bounded output.",
      args: "pattern, path, max_results, max_output_bytes"
    },
    %{
      name: "glob",
      permission: ":coding_file_read",
      description: "Find paths inside the pinned cwd jail.",
      args: "pattern, max_results"
    },
    %{
      name: "write",
      permission: ":coding_file_write",
      description: "Create one new file inside the pinned cwd jail.",
      args: "path, content, max_bytes"
    },
    %{
      name: "edit",
      permission: ":coding_file_write",
      description: "Apply an exact-match replacement inside one existing file.",
      args: "path, old_text, new_text, max_replacements"
    },
    %{
      name: "bash",
      permission: ":coding_shell_execute",
      description: "Run a cwd-jailed Level 1 command with timeout and redaction.",
      args: "executable+args or tier-only raw command, cwd, timeout_ms"
    }
  ]

  @system_prompt """
  You are Allbert Pi-mode, a focused coding assistant inside one pinned local repo.
  Follow the user's request, DEVELOPMENT.md, AGENTS.md hierarchy, active plan docs,
  ADRs, and existing code style. Gather context with bounded reads and searches;
  do not ingest whole files unless the operator asks and limits allow it. Use only
  six coding tools: read, grep, glob, write, edit, bash. Every tool is a registered
  Allbert action through Actions.Runner and Security Central. Routing and model
  output never grant authority. For effectful work, rely on policy, confirmation,
  tests, and deterministic evidence; never claim completion without verification.
  """

  @type tool_definition :: %{
          required(:name) => String.t(),
          required(:permission) => String.t(),
          required(:description) => String.t(),
          required(:args) => String.t()
        }

  @type bundle :: %{
          required(:system_prompt) => String.t(),
          required(:tools) => [tool_definition()],
          required(:tokenizer) => String.t(),
          required(:token_budget) => pos_integer(),
          required(:token_count) => non_neg_integer(),
          required(:within_budget?) => boolean()
        }

  @spec system_prompt() :: String.t()
  def system_prompt, do: String.trim(@system_prompt)

  def tool_definitions, do: @tool_definitions

  @spec surface_bundle(keyword()) :: bundle()
  def surface_bundle(opts \\ []) do
    tokenizer = Keyword.get(opts, :tokenizer, Config.prompt_tokenizer())
    token_budget = Keyword.get(opts, :token_budget, Config.prompt_token_budget())
    tools = tool_definitions()
    token_count = token_count([system_prompt(), inspect(tools)], tokenizer)

    %{
      system_prompt: system_prompt(),
      tools: tools,
      tokenizer: tokenizer,
      token_budget: token_budget,
      token_count: token_count,
      within_budget?: token_count <= token_budget
    }
  end

  @spec token_count(iodata() | term(), String.t()) :: non_neg_integer()
  def token_count(term, "simple_words") do
    term
    |> text()
    |> then(&Regex.scan(~r/[A-Za-z0-9_@.\/:-]+|[^\s]/, &1))
    |> length()
  end

  defp text(term) when is_binary(term) or is_list(term), do: IO.iodata_to_binary(term)
  defp text(term), do: inspect(term)
end
