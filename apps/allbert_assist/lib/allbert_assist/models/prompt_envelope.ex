defmodule AllbertAssist.Models.PromptEnvelope do
  @moduledoc """
  Canonical role boundary for single-turn model requests.

  Allbert-authored instructions and declarative rules occupy the system role.
  Operator text, retrieved context, registered metadata, and attachments remain
  user-role content. The envelope is a pure transformation: it owns no model,
  process, routing, permission, or execution authority.

  Multi-turn model consumers may keep their purpose-built context managers, but
  they must preserve the same provenance rule. Non-chat APIs such as embeddings
  and image generation do not use this envelope because they have no message
  roles.
  """

  alias ReqLLM.Context
  alias ReqLLM.Message.ContentPart

  @schema_version 2

  @type rule :: {atom(), String.t()}
  @type user_content :: String.t() | [ContentPart.t()]

  @spec build(keyword()) :: {:ok, Context.t()} | {:error, term()}
  def build(opts) when is_list(opts) do
    with {:ok, purpose} <- purpose(opts),
         {:ok, instruction} <- nonempty_text(Keyword.get(opts, :instruction), :instruction),
         {:ok, rules} <- rules(Keyword.get(opts, :rules)),
         {:ok, input} <- user_content(Keyword.get(opts, :input)),
         {:ok, input_class} <- input_class(Keyword.get(opts, :input_class, :operator_input)),
         {:ok, reference_context} <- reference_context(Keyword.get(opts, :reference_context)),
         {:ok, input_metadata} <- metadata(Keyword.get(opts, :input_metadata, %{})) do
      rule_ids = Enum.map(rules, &elem(&1, 0))

      messages =
        [
          Context.system(
            render_system(instruction, rules),
            envelope_metadata(purpose, :allbert_instructions, rule_ids)
          )
        ]
        |> maybe_add_reference_context(reference_context, purpose, rule_ids)
        |> Kernel.++([
          Context.user(
            input,
            Map.put(
              input_metadata,
              :allbert_prompt,
              prompt_metadata(purpose, input_class, rule_ids)
            )
          )
        ])

      messages
      |> Context.new()
      |> Context.validate()
    end
  end

  def build(_opts), do: {:error, :invalid_prompt_envelope_options}

  defp purpose(opts) do
    case Keyword.get(opts, :purpose) do
      purpose when is_atom(purpose) and not is_nil(purpose) -> {:ok, purpose}
      _other -> {:error, :invalid_prompt_purpose}
    end
  end

  defp rules(rules) when is_list(rules) and rules != [] do
    with true <- Enum.all?(rules, &valid_rule?/1),
         ids = Enum.map(rules, &elem(&1, 0)),
         true <- length(ids) == MapSet.size(MapSet.new(ids)) do
      {:ok, Enum.map(rules, fn {id, text} -> {id, String.trim(text)} end)}
    else
      _other -> {:error, :invalid_prompt_rules}
    end
  end

  defp rules(_rules), do: {:error, :invalid_prompt_rules}

  defp valid_rule?({id, text}) when is_atom(id) and is_binary(text),
    do: String.trim(text) != ""

  defp valid_rule?(_rule), do: false

  defp nonempty_text(value, _field) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :empty_prompt_instruction}
      text -> {:ok, text}
    end
  end

  defp nonempty_text(_value, field), do: {:error, {:invalid_prompt_text, field}}

  defp user_content(value) when is_binary(value) do
    if String.trim(value) == "", do: {:error, :empty_prompt_input}, else: {:ok, value}
  end

  defp user_content([%ContentPart{} | _rest] = parts) do
    if Enum.all?(parts, &match?(%ContentPart{}, &1)),
      do: {:ok, parts},
      else: {:error, :invalid_prompt_input}
  end

  defp user_content(_value), do: {:error, :invalid_prompt_input}

  defp input_class(value) when value in [:operator_input, :advisory_data], do: {:ok, value}
  defp input_class(_value), do: {:error, :invalid_prompt_input_class}

  defp reference_context(nil), do: {:ok, nil}

  defp reference_context(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      text -> {:ok, text}
    end
  end

  defp reference_context(_value), do: {:error, :invalid_prompt_reference_context}

  defp metadata(value) when is_map(value), do: {:ok, value}
  defp metadata(_value), do: {:error, :invalid_prompt_metadata}

  defp render_system(instruction, rules) do
    rendered_rules = Enum.map_join(rules, "\n", fn {id, text} -> "- [#{id}] #{text}" end)
    instruction <> "\n\nRules:\n" <> rendered_rules
  end

  defp maybe_add_reference_context(messages, nil, _purpose, _rule_ids), do: messages

  defp maybe_add_reference_context(messages, reference_context, purpose, rule_ids) do
    messages ++
      [
        Context.user(
          reference_context,
          envelope_metadata(purpose, :reference_context, rule_ids)
        )
      ]
  end

  defp envelope_metadata(purpose, content_class, rule_ids) do
    %{allbert_prompt: prompt_metadata(purpose, content_class, rule_ids)}
  end

  defp prompt_metadata(purpose, content_class, rule_ids) do
    %{
      schema_version: @schema_version,
      purpose: purpose,
      content_class: content_class,
      rule_ids: rule_ids
    }
  end
end
