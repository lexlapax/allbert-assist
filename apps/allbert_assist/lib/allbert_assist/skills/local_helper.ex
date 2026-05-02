defmodule AllbertAssist.Skills.LocalHelper do
  @moduledoc """
  Local skill validation and scaffold helpers.

  Helpers operate on standard Agent Skill directories. They never generate
  Elixir modules, scripts, package manifests, or executable adapters.
  """

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Paths
  alias AllbertAssist.Skills
  alias AllbertAssist.Skills.CapabilityContract
  alias AllbertAssist.Skills.Parser

  @doc "Validate a local skill directory without trusting or executing it."
  @spec validate_dir(String.t()) :: map()
  def validate_dir(path) when is_binary(path) do
    root_path = Path.expand(path)

    case Parser.parse_dir(root_path) do
      {:ok, spec} ->
        contract = CapabilityContract.from_metadata(spec.metadata)
        contract_validation = CapabilityContract.validate(contract)

        %{
          status: validation_status(spec.diagnostics, contract_validation),
          path: root_path,
          name: Skills.normalize_name(spec.name),
          description: spec.description,
          contract: contract_summary(contract, contract_validation),
          diagnostics: spec.diagnostics ++ contract_validation.diagnostics
        }

      {:error, diagnostics} ->
        %{
          status: :invalid,
          path: root_path,
          name: nil,
          description: nil,
          contract:
            contract_summary(
              %CapabilityContract{},
              CapabilityContract.validate(%CapabilityContract{})
            ),
          diagnostics: diagnostics
        }
    end
  end

  @doc "Create a standard local `SKILL.md` wrapper for an existing registered action."
  @spec create_skill(map()) :: {:ok, map()} | {:error, term()}
  def create_skill(attrs) when is_map(attrs) do
    with {:ok, name} <- required_string(attrs, :name),
         {:ok, action} <- required_string(attrs, :action),
         {:ok, permission} <- required_string(attrs, :permission) do
      name = Skills.normalize_name(name)
      action = to_string(action)
      permission = to_string(permission)
      description = normalized_description(attr(attrs, :description), action)
      confirmation = attr(attrs, :confirmation) || default_confirmation(action)
      root = attrs |> attr(:root, Paths.skills_root()) |> Path.expand()
      overwrite? = attr(attrs, :overwrite, false)

      contract =
        CapabilityContract.from_metadata(%{
          "allbert.actions" => action,
          "allbert.permissions" => permission,
          "allbert.confirmation" => to_string(confirmation)
        })

      validation = CapabilityContract.validate(contract)

      with :ok <- require_non_empty_name(name),
           :ok <- require_valid_contract(validation),
           {:ok, skill_root} <-
             write_skill(root, name, action, permission, description, confirmation, overwrite?) do
        {:ok,
         %{
           status: :created,
           path: skill_root,
           skill_md_path: Path.join(skill_root, "SKILL.md"),
           validation: validate_dir(skill_root)
         }}
      end
    end
  end

  defp validation_status(parser_diagnostics, contract_validation) do
    if Enum.any?(parser_diagnostics ++ contract_validation.diagnostics, &(&1.severity == :error)) do
      :invalid
    else
      :valid
    end
  end

  defp contract_summary(contract, validation) do
    %{
      status: contract.status,
      actions: contract.actions,
      permissions: contract.permissions,
      confirmation: contract.confirmation,
      validation_status: validation.status,
      execution_eligible?: validation.execution_eligible?,
      diagnostics: validation.diagnostics
    }
  end

  defp default_confirmation(action) do
    case Registry.capability(action) do
      {:ok, capability} -> capability.confirmation || :not_required
      {:error, _reason} -> :not_required
    end
  end

  defp normalized_description(nil, action), do: "Use the #{action} Allbert action."
  defp normalized_description("", action), do: normalized_description(nil, action)

  defp normalized_description(description, _action) do
    description
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp attr(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, to_string(key), default))
  end

  defp required_string(attrs, key) do
    case attr(attrs, key) do
      value when is_binary(value) -> required_trimmed_string(value, key)
      _value -> {:error, {:missing_required_attr, key}}
    end
  end

  defp required_trimmed_string(value, key) do
    case String.trim(value) do
      "" -> {:error, {:missing_required_attr, key}}
      trimmed -> {:ok, trimmed}
    end
  end

  defp require_non_empty_name(""), do: {:error, {:invalid_skill_name, ""}}
  defp require_non_empty_name(_name), do: :ok

  defp require_valid_contract(%{status: :valid}), do: :ok
  defp require_valid_contract(validation), do: {:error, {:invalid_contract, validation}}

  defp write_skill(root, name, action, permission, description, confirmation, overwrite?) do
    skill_root = Path.join(root, name)
    skill_md_path = Path.join(skill_root, "SKILL.md")

    if File.exists?(skill_md_path) and not overwrite? do
      {:error, {:skill_exists, skill_md_path}}
    else
      with :ok <- File.mkdir_p(skill_root),
           :ok <-
             File.write(
               skill_md_path,
               skill_markdown(name, action, permission, description, confirmation)
             ) do
        {:ok, skill_root}
      else
        {:error, reason} -> {:error, {:write_failed, reason}}
      end
    end
  end

  defp skill_markdown(name, action, permission, description, confirmation) do
    """
    ---
    name: #{name}
    description: #{yaml_string(description)}
    compatibility: Allbert v0.06+. Local scaffold for registered action #{action}.
    allowed-tools: allbert:action:#{action}
    metadata:
      allbert.kind: capability
      allbert.version: "0.6.0"
      allbert.actions: #{action}
      allbert.permissions: #{permission}
      allbert.confirmation: #{confirmation}
      allbert.memory-effects: none
      allbert.trace-effects: records_selected_skill,records_permission_decision
    ---

    ## Workflow

    1. Use the `#{action}` Allbert action.
    2. Keep execution behind the registered action runner and Security Central.
    3. Do not execute scripts, shell commands, package installs, or external tools from this skill.
    """
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  defp yaml_string(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"#{escaped}\""
  end
end
