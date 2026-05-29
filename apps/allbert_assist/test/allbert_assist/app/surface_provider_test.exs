defmodule AllbertAssist.App.SurfaceProviderTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.App.SurfaceProvider

  defmodule DefaultProvider do
    use SurfaceProvider

    def surfaces, do: []
    def surface_catalog, do: []
  end

  defmodule OverrideProvider do
    use SurfaceProvider

    def surfaces, do: []
    def surface_catalog, do: []
    def fallback_surface(:home), do: {:ok, "Home fallback."}
    def fallback_surface(_surface_id), do: {:error, :not_found}
  end

  test "use macro marks modules as surface providers" do
    assert true in provider_markers(DefaultProvider)
  end

  test "default fallback_surface returns not_found" do
    assert {:error, :not_found} = DefaultProvider.fallback_surface(:missing)
  end

  test "default intent_descriptors returns no descriptors" do
    assert [] = DefaultProvider.intent_descriptors()
  end

  test "fallback_surface can be overridden" do
    assert {:ok, "Home fallback."} = OverrideProvider.fallback_surface(:home)
    assert {:error, :not_found} = OverrideProvider.fallback_surface(:other)
  end

  defp provider_markers(module) do
    module.module_info(:attributes)
    |> Keyword.get_values(:allbert_surface_provider)
    |> List.flatten()
  end
end
