defmodule AllbertAssist.App.SurfaceProvider do
  @moduledoc """
  Declarative surface provider contract for Allbert workspace apps.

  Surface providers register validated surface metadata. They do not mount
  routes, execute actions, grant permissions, or own app domain state.
  """

  @callback surfaces() :: [AllbertAssist.Surface.t()]
  @callback surface_catalog() :: [AllbertAssist.Surface.catalog_entry()]
  @callback intent_descriptors() :: [map()]
  @callback fallback_surface(surface_id :: atom()) :: {:ok, String.t()} | {:error, :not_found}

  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :allbert_surface_provider, persist: true)
      @allbert_surface_provider true

      def intent_descriptors, do: []

      def fallback_surface(_surface_id), do: {:error, :not_found}

      defoverridable intent_descriptors: 0, fallback_surface: 1
    end
  end
end
