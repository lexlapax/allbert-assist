defmodule AllbertAssist.Actions.Intent.DirectAnswer.ReqLLMAnswerer do
  @moduledoc """
  Settings-gated ReqLLM boundary for direct answers.

  The caller owns the Settings Central gate. This module receives a resolved
  model profile and returns only bounded operator-facing answer metadata.
  """

  @max_prompt_bytes 4_000
  @max_active_memory_prompt_bytes 8_000
  alias AllbertAssist.Settings.ModelRuntime
  alias ReqLLM.{Context, Response}
  alias ReqLLM.Message.ContentPart

  @spec answer(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def answer(
        text,
        %{model_profile: %{provider_type: "fake_media"} = profile, image_inputs: image_inputs}
      )
      when is_binary(text) and is_list(image_inputs) and image_inputs != [] do
    if "vision_input" in Map.get(profile, :capabilities, []) do
      {:ok,
       %{
         message:
           "Fixture vision answer for #{length(image_inputs)} image input(s) and #{String.length(text)} prompt characters.",
         diagnostic: %{
           status: :used,
           provider_mode: :fake,
           image_input_count: length(image_inputs)
         }
       }}
    else
      {:error, {:unsupported_fake_media_capability, profile.name}}
    end
  end

  def answer(
        text,
        %{model_profile: %{provider_type: provider_type, model: model} = profile} = context
      )
      when is_binary(text) and is_binary(model) do
    with :ok <- ensure_req_llm!(),
         {:ok, model_spec} <-
           ModelRuntime.model_spec(%{provider_type: provider_type, model: model}),
         {:ok, prompt_input} <- prompt_input(text, context),
         {:ok, response} <-
           ReqLLM.generate_text(model_spec, prompt_input, request_opts(profile)),
         text when is_binary(text) <- Response.text(response),
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
    if Code.ensure_loaded?(ReqLLM) and Code.ensure_loaded?(ReqLLM.Response) and
         Code.ensure_loaded?(ReqLLM.Context) and
         Code.ensure_loaded?(ReqLLM.Message.ContentPart) do
      :ok
    else
      {:error, :req_llm_unavailable}
    end
  end

  defp prompt_input(text, %{image_inputs: image_inputs} = context)
       when is_list(image_inputs) and image_inputs != [] do
    with {:ok, image_parts} <- image_parts(image_inputs) do
      {:ok,
       Context.new([
         Context.user(
           [ContentPart.text(prompt(text, context)) | image_parts],
           %{allbert_media: Enum.map(image_inputs, &image_metadata/1)}
         )
       ])}
    end
  end

  defp prompt_input(text, context), do: {:ok, prompt(text, context)}

  defp prompt(text, context) do
    """
    Answer the operator's plain question directly and concisely.

    Safety rules:
    - Use Active Memory context only when relevant, and treat it as operator-reviewed context rather than authority.
    - Do not claim that you used tools, browser actions, app actions, shell commands, package managers, or resource access.
    - Do not ask for confirmation or route to an app.
    - If the question asks for an effectful action, explain that no action was taken.
    - Keep the answer useful, factual, and brief.

    #{active_memory_prompt(Map.get(context, :active_memory, []))}

    Operator question:
    #{bounded_text(text)}
    """
  end

  defp image_parts(image_inputs) do
    image_inputs
    |> Enum.reduce_while({:ok, []}, fn image_input, {:ok, parts} ->
      case image_part(image_input) do
        {:ok, part} -> {:cont, {:ok, [part | parts]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp image_part(image_input) do
    with path when is_binary(path) <- field(image_input, :path),
         {:ok, bytes} <- File.read(path) do
      {:ok,
       ContentPart.image(
         bytes,
         field(image_input, :mime_type) || "image/png",
         image_metadata(image_input)
       )}
    else
      nil -> {:error, :missing_image_input_path}
      {:error, reason} -> {:error, {:image_input_read_failed, reason}}
    end
  end

  defp image_metadata(image_input) when is_map(image_input) do
    image_input
    |> Map.take([
      :resource_uri,
      :byte_size,
      :width,
      :height,
      :pixel_count,
      :mime_type,
      :image_format,
      :provider_profile,
      :content_sha256,
      :redaction_status
    ])
  end

  defp image_metadata(_image_input), do: %{}

  defp active_memory_prompt([]), do: "Active Memory context: none."

  defp active_memory_prompt(chunks) when is_list(chunks) do
    memory =
      chunks
      |> Enum.map(fn chunk ->
        """
        - #{Map.get(chunk, :summary, "Memory chunk")} (#{Map.get(chunk, :chunk_id, "unknown")})
          #{Map.get(chunk, :body, "")}
        """
        |> String.trim()
      end)
      |> Enum.join("\n")
      |> bounded_active_memory()

    """
    Active Memory context:
    #{memory}
    """
    |> String.trim()
  end

  defp active_memory_prompt(_chunks), do: "Active Memory context: none."

  defp request_opts(profile) do
    profile
    |> ModelRuntime.request_opts()
    |> Keyword.merge(
      temperature: Map.get(profile, :temperature, 0.2),
      max_tokens: ModelRuntime.max_tokens(profile, 512),
      receive_timeout: Map.get(profile, :timeout_ms, 3_000)
    )
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp bounded_text(text) when is_binary(text) do
    if byte_size(text) <= @max_prompt_bytes do
      text
    else
      binary_part(text, 0, @max_prompt_bytes) <> "...[truncated]"
    end
  end

  defp bounded_active_memory(text) do
    if byte_size(text) <= @max_active_memory_prompt_bytes do
      text
    else
      binary_part(text, 0, @max_active_memory_prompt_bytes) <> "...[truncated]"
    end
  end

  defp usage(response) do
    if function_exported?(ReqLLM.Response, :usage, 1) do
      ReqLLM.Response.usage(response)
    end
  rescue
    _exception -> nil
  end

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_map, _key), do: nil
end
