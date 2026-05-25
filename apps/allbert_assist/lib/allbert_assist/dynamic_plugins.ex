defmodule AllbertAssist.DynamicPlugins do
  @moduledoc """
  Public v0.37 facade for dynamic draft metadata and inspection.

  M1 is intentionally file-backed and read-only for operator inspection, except
  for operator-owned metadata writes through this facade. Sandbox trial, trusted
  validation, live loading, and rollback arrive in later v0.37 milestones and
  must continue to use this facade instead of ordinary plugin discovery.
  """

  alias AllbertAssist.DynamicPlugins.Draft
  alias AllbertAssist.DynamicPlugins.MetadataStore
  alias AllbertAssist.Paths

  @doc "Return dynamic plugin roots."
  @spec roots() :: %{root: String.t(), drafts: String.t(), integrated: String.t()}
  def roots do
    %{
      root: Paths.dynamic_plugins_root(),
      drafts: Paths.dynamic_plugins_drafts_root(),
      integrated: Paths.dynamic_plugins_integrated_root()
    }
  end

  @doc "Create or rewrite draft metadata."
  @spec put_draft(map() | Draft.t(), keyword()) :: {:ok, Draft.t()} | {:error, term()}
  defdelegate put_draft(attrs_or_draft, opts \\ []), to: MetadataStore

  @doc "Read one draft."
  @spec get_draft(String.t()) :: {:ok, Draft.t()} | {:error, term()}
  defdelegate get_draft(slug), to: MetadataStore

  @doc "List draft summaries."
  @spec list_drafts() :: [map()]
  def list_drafts do
    MetadataStore.list_drafts()
    |> Enum.map(&Draft.summary/1)
  end

  @doc "Return one draft summary."
  def show_draft(slug) do
    with {:ok, draft} <- MetadataStore.get_draft(slug) do
      {:ok, Draft.summary(draft)}
    end
  end

  @doc "Read one integration summary."
  def show_integration(slug, revision \\ nil) do
    with {:ok, draft} <- MetadataStore.get_integration(slug, revision) do
      {:ok, Draft.summary(draft)}
    end
  end

  @doc "List integration summaries."
  @spec list_integrations() :: [map()]
  def list_integrations do
    MetadataStore.list_integrations()
    |> Enum.map(&Draft.summary/1)
  end

  @doc "Discard an inert or rolled-back draft."
  @spec discard_draft(String.t(), keyword()) :: {:ok, Draft.t()} | {:error, term()}
  defdelegate discard_draft(slug, opts \\ []), to: MetadataStore

  @doc "Verify draft source hashes."
  @spec verify_source_hashes(String.t()) :: :ok | {:error, term()}
  def verify_source_hashes(slug) do
    with {:ok, draft} <- MetadataStore.get_draft(slug) do
      MetadataStore.verify_source_hashes(draft)
    end
  end
end
