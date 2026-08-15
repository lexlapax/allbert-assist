defmodule AllbertAssist.Pack.CandidateBuilder.ExtractedAliases do
  @moduledoc false

  alias AllbertAssist.Pack.{Canonical, CompatibilityAlias, Contribution, Row, RowSchemas, Target}
  alias AllbertAssist.Pack.{PathSegment, ValidationDiagnostic}

  @mappings [
    {"allbert.artifacts", "AllbertArtifacts.Plugin", "allbert_artifacts",
     "AllbertArtifacts.Pack"},
    {"allbert.browser", "AllbertBrowser.Plugin", "allbert_browser", "AllbertBrowser.Pack"},
    {"allbert.discord", "AllbertDiscord.Plugin", "allbert_discord", "AllbertDiscord.Pack"},
    {"allbert.email", "AllbertEmail.Plugin", "allbert_email", "AllbertEmail.Pack"},
    {"allbert.matrix", "AllbertMatrix.Plugin", "allbert_matrix", "AllbertMatrix.Pack"},
    {"allbert.notes_files", "AllbertNotesFiles.Plugin", "allbert_notes_files",
     "AllbertNotesFiles.Pack"},
    {"allbert.research", "AllbertResearch.Plugin", "allbert_research", "AllbertResearch.Pack"},
    {"allbert.signal", "AllbertSignal.Plugin", "allbert_signal", "AllbertSignal.Pack"},
    {"allbert.slack", "AllbertSlack.Plugin", "allbert_slack", "AllbertSlack.Pack"},
    {"allbert.telegram", "AllbertTelegram.Plugin", "allbert_telegram", "AllbertTelegram.Pack"},
    {"allbert.tui", "AllbertTUI.Plugin", "allbert_tui", "AllbertTUI.Pack"},
    {"allbert.whatsapp", "AllbertWhatsApp.Plugin", "allbert_whatsapp", "AllbertWhatsApp.Pack"},
    {"stocksage", "StockSage.Plugin", "allbert_stocksage", "StockSage.Pack"}
  ]

  @spec apply([Contribution.t()], [map()]) ::
          {:ok, [Contribution.t()], [CompatibilityAlias.t()]}
          | {:error, [ValidationDiagnostic.t()]}
  def apply(contributions, plugins) when is_list(contributions) and is_list(plugins) do
    case validate_mapping_inventory(contributions, plugins) do
      :none ->
        {:ok, contributions, []}

      :full ->
        Enum.reduce_while(@mappings, {:ok, contributions, []}, fn mapping,
                                                                  {:ok, current, aliases} ->
          case migrate_mapping(mapping, current) do
            {:ok, migrated, alias_record} ->
              {:cont, {:ok, migrated, aliases ++ [alias_record]}}

            {:error, diagnostics} ->
              {:halt, {:error, diagnostics}}
          end
        end)

      {:error, _diagnostics} = error ->
        error
    end
  rescue
    _error -> invalid(:extracted_alias_migration_failed)
  end

  def apply(_contributions, _plugins), do: invalid(:invalid_extracted_alias_input)

  @doc false
  @spec mappings() :: [{String.t(), String.t(), String.t(), String.t()}]
  def mappings, do: @mappings

  defp validate_mapping_inventory(contributions, plugins) do
    expected_sources = @mappings |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    expected_targets = @mappings |> Enum.map(&elem(&1, 2)) |> Enum.sort()
    contribution_ids = MapSet.new(contributions, & &1.owner.id)

    shipped_sources =
      plugins
      |> Enum.filter(&(&1.source == :shipped and not is_nil(&1.module)))
      |> Enum.map(& &1.plugin_id)
      |> Enum.sort()

    mapped_product_present? =
      Enum.any?(expected_sources ++ expected_targets, &MapSet.member?(contribution_ids, &1))

    cond do
      not mapped_product_present? and shipped_sources == [] ->
        :none

      shipped_sources == expected_sources and validate_mapping_pairs(contributions) == :ok ->
        :full

      shipped_sources != expected_sources ->
        invalid(:extracted_alias_source_roster_mismatch)

      true ->
        validate_mapping_pairs(contributions)
    end
  end

  defp validate_mapping_pairs(contributions) do
    Enum.reduce_while(@mappings, :ok, fn
      {source_id, source_module, target_id, target_module}, :ok ->
        source = contribution(contributions, source_id)
        target = contribution(contributions, target_id)

        case {source, target} do
          {%Contribution{} = source, %Contribution{} = target} ->
            if exact_mapping?(source, source_module, target, target_module) do
              {:cont, :ok}
            else
              {:halt, invalid(:extracted_alias_mapping_mismatch, source_id)}
            end

          _missing_or_partial ->
            {:halt, invalid(:incomplete_extracted_alias_mapping, source_id)}
        end
    end)
  end

  defp exact_mapping?(source, source_module, target, target_module) do
    source.owner.kind == :legacy_plugin and
      module_name(source.implementation_module) == source_module and
      source.source_lane == :legacy_plugin and
      source.compatibility.kind == :legacy_plugin and
      source.compatibility.trust == :trusted and
      source.compatibility.enabled == true and
      target.owner.kind == :compiled_pack and
      module_name(target.implementation_module) == target_module and
      target.source_lane == :native and
      target.compatibility.kind == :native and
      target.compatibility.trust == :trusted and
      target.compatibility.enabled == true
  end

  defp migrate_mapping({source_id, _source_module, target_id, _target_module}, contributions) do
    source = contribution(contributions, source_id)
    target = contribution(contributions, target_id)

    alias_target = %Target{
      schema_version: 1,
      kind: :contribution,
      owner_id: target_id,
      identity: target_id
    }

    migrated_target = migrate_callbacks(source, target)

    deprecated_source = %{
      source
      | compatibility: %{
          source.compatibility
          | kind: :deprecated_alias,
            alias_of: alias_target
        }
    }

    with {:ok, authority} <-
           Canonical.contribution_alias_authority(deprecated_source, migrated_target) do
      alias_record = %CompatibilityAlias{
        schema_version: 1,
        kind: :deprecated_alias,
        owner_id: source_id,
        target: alias_target,
        module: source.implementation_module,
        authority_sha256: authority.authority_sha256
      }

      migrated =
        Enum.map(contributions, fn
          %Contribution{owner: %{id: ^source_id}} -> deprecated_source
          %Contribution{owner: %{id: ^target_id}} -> migrated_target
          contribution -> contribution
        end)

      {:ok, migrated, alias_record}
    else
      _error -> invalid(:extracted_alias_authority_mismatch, source_id)
    end
  end

  defp module_name(module) when is_atom(module) do
    module |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
  end

  defp module_name(_module), do: nil

  defp migrate_callbacks(source, target) do
    callbacks =
      Map.new(source.callbacks, fn {family, rows} ->
        migrated_rows =
          rows
          |> Enum.reject(&compatibility_only_action?/1)
          |> Enum.map(&RowSchemas.reattribute!(&1, source, target))

        target_rows = Map.fetch!(target.callbacks, family)

        merged_rows =
          Enum.reduce(migrated_rows, target_rows, fn row, rows ->
            projection = RowSchemas.alias_authority_projection!(row, target)

            if Enum.any?(
                 rows,
                 &(RowSchemas.alias_authority_projection!(&1, target) == projection)
               ) do
              rows
            else
              rows ++ [row]
            end
          end)

        {family, merged_rows}
      end)

    %{target | callbacks: callbacks}
  end

  defp compatibility_only_action?(%Row{kind: :actions, order: %{namespace: :alias_target}}),
    do: true

  defp compatibility_only_action?(_row), do: false

  defp contribution(contributions, id) do
    case Enum.filter(contributions, &(&1.owner.id == id)) do
      [contribution] -> contribution
      [] -> nil
      _duplicates -> raise ArgumentError, "duplicate contribution owner"
    end
  end

  defp invalid(reason, owner_id \\ nil) do
    path =
      [%PathSegment{schema_version: 1, kind: :field, value: "extracted_aliases"}] ++
        if(is_nil(owner_id),
          do: [],
          else: [%PathSegment{schema_version: 1, kind: :identity, value: owner_id}]
        )

    {:error,
     [
       %ValidationDiagnostic{
         schema_version: 1,
         code: :invalid_value,
         path: path,
         owner: nil,
         detail: %{reason: reason}
       }
     ]}
  end
end
