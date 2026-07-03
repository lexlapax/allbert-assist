defmodule AllbertAssistWeb.Live.SharedShellHooks do
  @moduledoc """
  Shared shell-chrome events for every LiveView shell (v0.61b M7, ADR 0080 §2).

  The theme toggle and overflow menu moved from the retired workspace appbar
  into the product sidebar footer, which renders on every shell — this
  `on_mount` hook is the single owner of their events
  (`toggle_workspace_theme`, `toggle_workspace_overflow_menu`) so an operator
  LiveView can never crash on a control it did not handle. The theme write
  stays on the registered-action spine (`Runner.run("set_workspace_theme", …)`
  with server-derived identity via `ContextBuilder`), and the
  `allbert:set-theme` push keeps `<html data-theme>` in step through the
  ThemeSync hook exactly as the workspace shell did (v0.61 M10.3 P1).
  """

  import Phoenix.Component, only: [assign: 3, assign_new: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, push_event: 3]

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Settings.Schema
  alias AllbertAssist.Surfaces.ContextBuilder

  @sidebar_states ~w(expanded rail hidden)

  def on_mount(:shell_chrome, _params, _session, socket) do
    socket =
      socket
      # M9.2: only the connected mount runs the settings-snapshot action — the
      # disconnected HTTP render defaulted to a per-request Runner invocation
      # any anonymous GET triggered; the root layout resolves the page theme
      # itself, so "system" is a safe first-paint default for the toggle icon.
      |> assign_new(:workspace_theme, fn ->
        if connected?(socket), do: theme_from_settings(), else: "system"
      end)
      |> assign_new(:workspace_high_contrast?, fn -> false end)
      |> assign_new(:workspace_overflow_open?, fn -> false end)
      |> assign_new(:sidebar_state, fn -> "expanded" end)

    {:cont, attach_hook(socket, :shared_shell_chrome, :handle_event, &handle_event/3)}
  end

  defp handle_event("toggle_workspace_theme", _params, socket) do
    next_theme = next_workspace_theme(socket.assigns.workspace_theme)

    context =
      ContextBuilder.live_view_context(socket, surface: inspect(socket.view))

    case Runner.run("set_workspace_theme", %{theme: next_theme}, context) do
      {:ok, %{status: :completed, theme: theme}} ->
        {:halt,
         socket
         |> assign(:workspace_theme, theme)
         |> push_event("allbert:set-theme", %{theme: theme})}

      _other ->
        {:halt, socket}
    end
  end

  defp handle_event("toggle_workspace_overflow_menu", _params, socket) do
    {:halt, assign(socket, :workspace_overflow_open?, !socket.assigns.workspace_overflow_open?)}
  end

  defp handle_event("close_workspace_overflow_menu", _params, socket) do
    {:halt, assign(socket, :workspace_overflow_open?, false)}
  end

  # v0.61b M8 (ADR 0080 §4): sidebar collapse — expanded ↔ rail cycle, a
  # separate full-hide toggle, and the client restore from LayoutPrefs.
  defp handle_event("cycle_sidebar_state", _params, socket) do
    next =
      case socket.assigns.sidebar_state do
        "expanded" -> "rail"
        _rail_or_hidden -> "expanded"
      end

    {:halt, assign(socket, :sidebar_state, next)}
  end

  # M9.2 (ADR 0080 focus-return guardrail): both hide transitions strand focus
  # on a control the patch removes — hiding removes the whole sidebar,
  # reopening removes the reopen tab — so each pushes focus to the surviving
  # counterpart (the allbert:focus window listener in app.js).
  defp handle_event("toggle_sidebar_hidden", _params, socket) do
    case socket.assigns.sidebar_state do
      "hidden" ->
        {:halt,
         socket
         |> assign(:sidebar_state, "expanded")
         |> push_event("allbert:focus", %{id: "product-sidebar-toggle"})}

      _expanded_or_rail ->
        {:halt,
         socket
         |> assign(:sidebar_state, "hidden")
         |> push_event("allbert:focus", %{id: "product-sidebar-reopen"})}
    end
  end

  defp handle_event("set_sidebar_state", %{"state" => state}, socket)
       when state in @sidebar_states do
    {:halt, assign(socket, :sidebar_state, state)}
  end

  defp handle_event("set_sidebar_state", _params, socket), do: {:halt, socket}

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # Kept in sync with the 3-state cycle the workspace shell established
  # (system → dark → light → system, v0.26a M34).
  defp next_workspace_theme("system"), do: "dark"
  defp next_workspace_theme("dark"), do: "light"
  defp next_workspace_theme("light"), do: "system"
  defp next_workspace_theme(_theme), do: "dark"

  # The theme read rides the registered resolved-settings snapshot action —
  # the same one-spine read the workspace shell uses at mount.
  defp theme_from_settings do
    context =
      ContextBuilder.live_view_context(%{},
        surface: "AllbertAssistWeb.Live.SharedShellHooks"
      )

    "resolved_settings_snapshot"
    |> Runner.run(%{}, context)
    |> theme_from_snapshot()
  end

  @doc """
  Resolves the workspace theme from a `resolved_settings_snapshot` action
  result, falling back to `"system"` on any failure or unknown value —
  a broken snapshot action must pin the shells to a safe theme, never crash
  the mount. Public so the fallback branch is unit-testable (M9.2).
  """
  def theme_from_snapshot({:ok, %{status: :completed, settings: settings}})
      when is_map(settings) do
    case Schema.get_dotted(settings, "workspace.theme.mode") do
      theme when theme in ["dark", "light", "system"] -> theme
      _other -> "system"
    end
  end

  def theme_from_snapshot(_other), do: "system"
end
