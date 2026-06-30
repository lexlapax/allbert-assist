defmodule AllbertAssist.Actions.Helper do
  @moduledoc """
  Shared helpers for action invocation call sites.
  """

  alias AllbertAssist.Actions.ErrorExtraction
  alias AllbertAssist.Actions.Runner

  @type completed_response :: %{required(:status) => term(), optional(any()) => any()}

  @spec completed_action(String.t() | atom(), map()) ::
          {:ok, completed_response()} | {:error, term()}
  def completed_action(action_name, params), do: completed_action(action_name, params, %{})

  @spec completed_action(String.t() | atom(), map(), map(), keyword()) ::
          {:ok, completed_response()} | {:error, term()}
  def completed_action(action_name, params, context, opts \\ []) do
    completed_status = Keyword.get(opts, :status, :completed)

    case Runner.run(action_name, params, context) do
      {:ok, %{status: status} = response} when status == completed_status ->
        {:ok, response}

      {:ok, response} ->
        {:error, error_response(response, opts)}
    end
  end

  defp error_response(response, opts) do
    case Keyword.get(opts, :error, :extracted) do
      :response -> response
      _mode -> ErrorExtraction.from_response(response)
    end
  end
end
