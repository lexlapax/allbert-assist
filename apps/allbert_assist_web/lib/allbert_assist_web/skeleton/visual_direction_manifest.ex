defmodule AllbertAssistWeb.Skeleton.VisualDirectionManifest do
  @moduledoc """
  v0.60b M3 manifest of the candidate visual directions and their preview hero paths.

  This is disposable design-exploration metadata, not the v0.61 build. It enumerates
  the ≥3 divergent candidate directions (`:a`, `:b`, `:c`) and, for M6, the operator's
  `:selected` proof direction, together with the four hero screens each direction is
  rendered as. The `/preview/visual/<direction>/<screen>` routes it describes are gated
  by the existing `:preview_routes` compile-env flag and read no business state.

  The paired `docs/design/visual-direction-{a,b,c}.md` specs and the
  `[data-visual-direction="a|b|c"]` token/theme deltas in `assets/css/app.css` are what
  make each direction render as genuinely distinct pixels.
  """

  @directions [:a, :b, :c]
  @selected_direction :selected
  @hero_screens [:workspace, :onboarding, :trust, :launch]

  @type direction :: :a | :b | :c
  @type screen :: :workspace | :onboarding | :trust | :launch

  @doc """
  The ≥3 candidate direction ids the operator chooses among (M3).
  """
  @spec directions() :: [direction(), ...]
  def directions, do: @directions

  @doc """
  The M6 selected-proof direction id (`:selected`); resolves the operator's chosen
  direction to the same styled-variant mechanism as the candidates.
  """
  @spec selected_direction() :: :selected
  def selected_direction, do: @selected_direction

  @doc """
  The four hero screens each direction is rendered as (workspace / onboarding / trust /
  launch — the landing/start surface).
  """
  @spec hero_screens() :: [screen(), ...]
  def hero_screens, do: @hero_screens

  @doc """
  The candidate direction × hero-screen preview paths the request-flow S4 greps
  (`/preview/visual/<direction>/<screen>`), one line per path.
  """
  @spec hero_paths() :: [String.t(), ...]
  def hero_paths do
    for direction <- @directions, screen <- @hero_screens do
      preview_path(direction, screen)
    end
  end

  @doc """
  The M6 selected-proof hero paths (`/preview/visual/selected/<screen>`).
  """
  @spec selected_hero_paths() :: [String.t(), ...]
  def selected_hero_paths do
    for screen <- @hero_screens, do: preview_path(@selected_direction, screen)
  end

  @doc """
  The preview path for one direction × screen.
  """
  @spec preview_path(direction() | :selected, screen()) :: String.t()
  def preview_path(direction, screen)
      when direction in [:a, :b, :c, :selected] and screen in @hero_screens do
    "/preview/visual/#{direction}/#{screen}"
  end

  @doc """
  Validates and normalizes a `direction` request param to a known direction id, raising
  `ArgumentError` for anything outside the candidate set plus `:selected`.
  """
  @spec fetch_direction!(String.t()) :: direction() | :selected
  def fetch_direction!(direction) when is_binary(direction) do
    case direction do
      "a" -> :a
      "b" -> :b
      "c" -> :c
      "selected" -> :selected
      other -> raise ArgumentError, "unknown v0.60b visual direction #{inspect(other)}"
    end
  end

  @doc """
  Validates and normalizes a `screen` request param to a known hero-screen id, raising
  `ArgumentError` for anything outside the four hero screens.
  """
  @spec fetch_screen!(String.t()) :: screen()
  def fetch_screen!(screen) when is_binary(screen) do
    case screen do
      "workspace" -> :workspace
      "onboarding" -> :onboarding
      "trust" -> :trust
      "launch" -> :launch
      other -> raise ArgumentError, "unknown v0.60b visual hero screen #{inspect(other)}"
    end
  end
end
