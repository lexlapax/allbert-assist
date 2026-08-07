defmodule AllbertAssist.Pack.ActivationGuard do
  @moduledoc "Kernel validation facade for the internal authorizing activation carrier."

  alias AllbertAssist.Pack.{ActivationContext, Readiness}

  @carrier_key :allbert_pack_activation

  @spec validate(keyword(), keyword()) ::
          :ok | {:error, :product_not_ready | :stale_activation}
  def validate(carrier, opts \\ []) do
    with {:ok, context} <- activation_context(carrier) do
      Readiness.validate_activation(context, opts)
    end
  end

  defp activation_context(carrier) when is_list(carrier) do
    if Keyword.keyword?(carrier) and
         carrier |> Keyword.keys() |> Enum.count(&(&1 == @carrier_key)) == 1 do
      case Keyword.fetch!(carrier, @carrier_key) do
        %ActivationContext{} = context -> {:ok, context}
        _other -> {:error, :product_not_ready}
      end
    else
      {:error, :product_not_ready}
    end
  end

  defp activation_context(_carrier), do: {:error, :product_not_ready}
end
