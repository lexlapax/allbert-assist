defmodule AllbertAssist.Actions.Intent.DirectAnswer.ReqLLMAnswerer do
  @moduledoc """
  Settings-gated ReqLLM boundary for direct answers.

  The caller owns the Settings Central gate. This module receives a resolved
  model profile and returns only bounded operator-facing answer metadata.
  """

  @max_prompt_bytes 4_000

  @spec answer(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def answer(text, %{model_profile: %{provider_type: provider_type, model: model} = profile})
      when is_binary(text) and is_binary(model) do
    with :ok <- ensure_req_llm!(),
         {:ok, model_spec} <- model_spec(provider_type, model),
         {:ok, response} <- ReqLLM.generate_text(model_spec, prompt(text), request_opts(profile)),
         text when is_binary(text) <- ReqLLM.Response.text(response),
         text <- String.trim(text),
         false <- text == "" do
      {:ok,
       %{
         message: text,
         diagnostic: %{
           status: :used,
           usage: usage(response)
         }
       }}
    else
      true -> {:error, :empty_model_text}
      nil -> {:error, :empty_model_text}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    :exit, reason -> {:error, reason}
  end

  def answer(_text, context),
    do: {:error, {:invalid_model_profile, Map.get(context, :model_profile)}}

  defp ensure_req_llm! do
    if Code.ensure_loaded?(ReqLLM) and Code.ensure_loaded?(ReqLLM.Response) do
      :ok
    else
      {:error, :req_llm_unavailable}
    end
  end

  defp model_spec("openai", model), do: {:ok, %{provider: :openai, id: model}}
  defp model_spec("openai_compatible", model), do: {:ok, %{provider: :openai, id: model}}
  defp model_spec(provider, _model), do: {:error, {:unsupported_model_provider, provider}}

  defp prompt(text) do
    """
    Answer the operator's plain question directly and concisely.

    Safety rules:
    - Do not claim that you used tools, files, memory, browser actions, app actions, shell commands, package managers, or resource access.
    - Do not ask for confirmation or route to an app.
    - If the question asks for an effectful action, explain that no action was taken.
    - Keep the answer useful, factual, and brief.

    Operator question:
    #{bounded_text(text)}
    """
  end

  defp request_opts(profile) do
    [
      temperature: Map.get(profile, :temperature, 0.2),
      max_tokens: Map.get(profile, :max_tokens, 512),
      receive_timeout: Map.get(profile, :timeout_ms, 3_000)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp bounded_text(text) when is_binary(text) do
    if byte_size(text) <= @max_prompt_bytes do
      text
    else
      binary_part(text, 0, @max_prompt_bytes) <> "...[truncated]"
    end
  end

  defp usage(response) do
    if function_exported?(ReqLLM.Response, :usage, 1) do
      ReqLLM.Response.usage(response)
    end
  rescue
    _exception -> nil
  end
end
