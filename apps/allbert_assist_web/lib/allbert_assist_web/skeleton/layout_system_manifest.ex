defmodule AllbertAssistWeb.Skeleton.LayoutSystemManifest do
  @moduledoc """
  v0.61 M1 manifest of the candidate layout systems and their per-surface preview paths.

  A layout system is a composition paradigm — a distinct answer to *where things go*
  (shell, primary canvas, context rail, utility surfaces, chat-primary hero; the nav
  posture; the responsive spine) — not a restyle. v0.61 M1 renders each system across
  **all nine** v0.60 IA surfaces in the operator-chosen **Direction C** visual language
  so the operator can preview real layouts side-by-side and choose one (`CHOSEN_LAYOUT`)
  in M2, before the build milestones implement it.

  Systems (operator decision at M1 kickoff — see `docs/plans/v0.61-plan.md` M1):
  `:a` Focused canvas, `:b` Workbench, `:c` Progressive shell, `:d` Sidebar-primary.

  The `/preview/layout/<system>/<surface>` routes are disposable design-exploration
  behind the existing `:preview_routes` flag: they read no business state, grant no
  authority, and are **not** the M3-M9 build. The nine surfaces are derived from
  `AllbertAssistWeb.Skeleton.RouteManifest` so this stays in sync with the IA.
  """

  alias AllbertAssistWeb.Skeleton.RouteManifest

  @systems [:a, :b, :c, :d]

  @type system :: :a | :b | :c | :d

  @doc """
  The candidate layout-system ids the operator chooses among (M2). Operator chose four
  at M1 kickoff (L-A/L-B/L-C plus L-D Sidebar-primary).
  """
  @spec systems() :: [system(), ...]
  def systems, do: @systems

  @doc """
  The nine IA surfaces each layout system is rendered across, in IA order, derived from
  the v0.60 walking-skeleton route manifest.
  """
  @spec surfaces() :: [atom(), ...]
  def surfaces, do: Enum.map(RouteManifest.routes(), & &1.route_id)

  @doc """
  The system × surface preview paths the request-flow S3 greps
  (`/preview/layout/<system>/<surface>`), one line per path — `systems × 9` in total.
  """
  @spec surface_paths() :: [String.t(), ...]
  def surface_paths do
    for system <- @systems, surface <- surfaces() do
      preview_path(system, surface)
    end
  end

  @doc """
  The preview path for one layout-system × surface.
  """
  @spec preview_path(system(), atom()) :: String.t()
  def preview_path(system, surface) when system in @systems and is_atom(surface) do
    "/preview/layout/#{system}/#{surface}"
  end

  @doc """
  Validates and normalizes a `system` request param to a known layout-system id, raising
  `ArgumentError` for anything outside the candidate set.
  """
  @spec fetch_system!(String.t()) :: system()
  def fetch_system!(system) when is_binary(system) do
    case system do
      "a" -> :a
      "b" -> :b
      "c" -> :c
      "d" -> :d
      other -> raise ArgumentError, "unknown v0.61 layout system #{inspect(other)}"
    end
  end

  @doc """
  Validates and normalizes a `surface` request param to a known IA surface id, raising
  `ArgumentError` for anything outside the nine surfaces.
  """
  @spec fetch_surface!(String.t()) :: atom()
  def fetch_surface!(surface) when is_binary(surface) do
    known = Map.new(surfaces(), &{Atom.to_string(&1), &1})

    case Map.fetch(known, surface) do
      {:ok, id} -> id
      :error -> raise ArgumentError, "unknown v0.61 IA surface #{inspect(surface)}"
    end
  end
end
