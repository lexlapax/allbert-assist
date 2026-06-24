defmodule AllbertAssist.Coding.Session do
  @moduledoc """
  Session-local Pi-mode state helpers.

  The state returned here is held by the TUI process. It is not durable
  authority, does not mutate Settings Central, and never bypasses registered
  coding actions for reads, writes, edits, or shell execution.
  """

  alias AllbertAssist.Coding.Config
  alias AllbertAssist.Coding.PathPolicy
  alias AllbertAssist.Coding.Prompt
  alias AllbertAssist.Settings

  @approval_modes ["default", "accept-edits", "plan", "tier"]

  @type t :: %{
          required(:cwd_jail) => String.t(),
          required(:model_profile) => String.t(),
          required(:approval_mode) => String.t(),
          required(:prompt) => Prompt.bundle(),
          required(:req_llm_context) => ReqLLM.Context.t(),
          required(:started_at) => String.t(),
          optional(:cleared_at) => String.t(),
          optional(:compacted_at) => String.t()
        }

  @spec start(String.t() | nil, map()) :: {:ok, t()} | {:error, term()}
  def start(path, context \\ %{}) do
    if Config.pi_mode_enabled?() do
      do_start(path, context)
    else
      {:error, :pi_mode_disabled}
    end
  end

  @spec switch_model(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def switch_model(session, profile_name) when is_binary(profile_name) do
    with {:ok, profile} <- Settings.resolve_model_profile(String.trim(profile_name)) do
      {:ok,
       session
       |> Map.put(:model_profile, profile.name)
       |> Map.put(:model, profile.model)
       |> Map.put(:provider, profile.provider)}
    end
  end

  def switch_model(_session, _profile_name), do: {:error, :invalid_model_profile}

  @spec set_approval_mode(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def set_approval_mode(session, mode) when is_binary(mode) do
    normalized =
      mode
      |> String.trim()
      |> String.replace("_", "-")

    if normalized in @approval_modes do
      {:ok, Map.put(session, :approval_mode, normalized)}
    else
      {:error, {:invalid_approval_mode, mode}}
    end
  end

  def set_approval_mode(_session, mode), do: {:error, {:invalid_approval_mode, mode}}

  @spec clear(t()) :: t()
  def clear(%{prompt: prompt} = session) do
    session
    |> Map.put(:req_llm_context, base_context(prompt))
    |> Map.put(:cleared_at, now())
  end

  @spec compact(t()) :: t()
  def compact(session) do
    session
    |> clear()
    |> Map.put(:compacted_at, now())
  end

  @spec merge_response(t(), ReqLLM.Response.t()) :: {:ok, t(), ReqLLM.Response.t()}
  def merge_response(session, response) do
    updated_response = ReqLLM.Context.merge_response(session.req_llm_context, response)

    updated_session =
      case Map.get(updated_response, :context) do
        %ReqLLM.Context{} = context -> Map.put(session, :req_llm_context, context)
        _other -> session
      end

    {:ok, updated_session, updated_response}
  end

  @spec metadata(t() | nil) :: map()
  def metadata(nil), do: %{}

  def metadata(session) do
    %{
      cwd_jail: session.cwd_jail,
      workspace_root: session.cwd_jail,
      pi_mode_enabled: true,
      approval_mode: session.approval_mode,
      default_approval_mode: session.approval_mode,
      model_profile: session.model_profile,
      prompt_token_count: session.prompt.token_count,
      prompt_tokenizer: session.prompt.tokenizer
    }
  end

  defp do_start(path, context) do
    prompt = Prompt.surface_bundle()

    with {:ok, cwd_jail} <- PathPolicy.jail(%{cwd_jail: chosen_path(path, context)}),
         {:ok, session} <- base_session(cwd_jail, prompt),
         {:ok, session} <- switch_model(session, Config.model_profile()) do
      {:ok, session}
    end
  end

  defp base_session(cwd_jail, prompt) do
    if prompt.within_budget? do
      {:ok,
       %{
         cwd_jail: cwd_jail,
         model_profile: Config.model_profile(),
         approval_mode: Config.default_approval_mode(),
         prompt: prompt,
         req_llm_context: base_context(prompt),
         started_at: now()
       }}
    else
      {:error, {:prompt_budget_exceeded, prompt.token_count, prompt.token_budget}}
    end
  end

  defp base_context(prompt) do
    prompt.system_prompt
    |> ReqLLM.Context.system()
    |> List.wrap()
    |> ReqLLM.Context.new()
    |> Map.put(:tools, prompt.tools)
  end

  defp chosen_path(path, context) when is_binary(path) do
    case String.trim(path) do
      "" -> Config.cwd_jail(context)
      value -> value
    end
  end

  defp chosen_path(_path, context), do: Config.cwd_jail(context)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
