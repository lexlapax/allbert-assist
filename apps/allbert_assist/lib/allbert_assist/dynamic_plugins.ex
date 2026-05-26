defmodule AllbertAssist.DynamicPlugins do
  @moduledoc """
  Public v0.37 facade for dynamic draft generation, inspection, and evidence runs.

  Dynamic drafts are file-backed Allbert Home data. Sandbox trial and gate
  evidence flows through the v0.36 sandbox facade and still grants no live
  authority. Trusted validation, live loading, rollback, and codegen draft
  requests must continue to use this facade instead of ordinary plugin
  discovery.
  """

  alias AllbertAssist.DynamicPlugins.Codegen
  alias AllbertAssist.DynamicPlugins.Codegen.Workflow
  alias AllbertAssist.DynamicPlugins.Draft
  alias AllbertAssist.DynamicPlugins.Loader
  alias AllbertAssist.DynamicPlugins.MetadataStore
  alias AllbertAssist.DynamicPlugins.SandboxBridge
  alias AllbertAssist.DynamicPlugins.Staging
  alias AllbertAssist.Paths

  @doc "Return dynamic plugin roots."
  @spec roots() :: %{
          root: String.t(),
          drafts: String.t(),
          integrated: String.t(),
          audit: String.t()
        }
  def roots do
    %{
      root: Paths.dynamic_plugins_root(),
      drafts: Paths.dynamic_plugins_drafts_root(),
      integrated: Paths.dynamic_plugins_integrated_root(),
      audit: Paths.dynamic_plugins_audit_root()
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

  @doc "Request a source-bearing read-only action draft for an explicit capability gap."
  @spec request_draft(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate request_draft(attrs, context \\ %{}, opts \\ []), to: Codegen.Agent

  @doc "Request a draft, then run trial/gate evidence with bounded repair."
  @spec request_draft_with_gate(map(), map(), keyword()) ::
          {:ok, Workflow.result()} | {:error, term()}
  defdelegate request_draft_with_gate(attrs, context \\ %{}, opts \\ []), to: Workflow

  @doc "Repair a source-bearing draft from bounded validation or sandbox evidence."
  @spec repair_draft(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate repair_draft(slug, evidence, context \\ %{}), to: Codegen.Producer

  @doc "Build a disposable staged project for one draft."
  @spec stage_draft(String.t(), keyword()) :: {:ok, Staging.t()} | {:error, term()}
  def stage_draft(slug, opts \\ []) do
    with {:ok, draft} <- MetadataStore.get_draft(slug) do
      Staging.build(draft, opts)
    end
  end

  @doc "Run compile/focused-test evidence for one draft through the v0.36 sandbox."
  defdelegate run_draft_trial(slug, opts \\ []), to: SandboxBridge, as: :run_trial

  @doc "Run warning-gate evidence for one draft through the v0.36 sandbox."
  defdelegate run_draft_gate(slug, opts \\ []), to: SandboxBridge, as: :run_gate

  @doc "Integrate one gate-passed draft after an approved confirmation."
  defdelegate integrate_draft(slug, opts \\ []), to: Loader, as: :integrate

  @doc "Rollback one live integration after an approved confirmation."
  defdelegate rollback_integration(slug, revision \\ nil, opts \\ []), to: Loader, as: :rollback

  @doc "Emergency-disable the live loader and clear dynamic authority."
  defdelegate disable_live_loader(opts \\ []), to: Loader, as: :disable

  @doc "Reconcile integrated metadata into the runtime overlay."
  defdelegate reconcile_integrations(opts \\ []), to: Loader, as: :reconcile
end
