defmodule AllbertAssist.Workflows do
  @moduledoc """
  Facade for v0.44 operator-authored workflow YAML.

  Workflow files are inert data under Allbert Home. This facade is a plain
  module because it holds no process state and grants no authority.
  """

  alias AllbertAssist.Workflows.{Expander, Loader, Validator}

  @spec list() :: {:ok, [map()], [term()]} | {:error, term()}
  def list, do: Loader.list_workflows()

  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  def load(workflow_id), do: Loader.load(workflow_id)

  @spec exists?(String.t()) :: boolean()
  def exists?(workflow_id), do: Loader.exists?(workflow_id)

  @spec inspect_workflow(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def inspect_workflow(workflow_id, opts \\ []) do
    with {:ok, workflow} <- Loader.load(workflow_id),
         {:ok, workflow} <- Validator.validate(workflow, opts) do
      {:ok, workflow}
    end
  end

  @spec expand(String.t(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def expand(workflow_id, inputs \\ %{}, context \\ %{}, opts \\ []) do
    with {:ok, workflow} <- inspect_workflow(workflow_id, opts) do
      Expander.expand(workflow, inputs, context)
    end
  end

  @spec preview(String.t(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def preview(workflow_id, inputs \\ %{}, context \\ %{}, opts \\ []) do
    expand(workflow_id, inputs, context, opts)
  end
end
