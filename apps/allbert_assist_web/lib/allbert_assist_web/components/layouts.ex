defmodule AllbertAssistWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use AllbertAssistWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :content_width, :string,
    default: "narrow",
    values: ["narrow", "wide", "full"],
    doc: "the width of the inner content container"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <a
      id="skip-to-content"
      href="#main-content"
      class="sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:z-50 focus:rounded focus:bg-base-100 focus:px-3 focus:py-2 focus:text-sm focus:font-semibold focus:outline-2 focus:outline-offset-2 focus:outline-base-content"
    >
      Skip to content
    </a>

    <main id="main-content" tabindex="-1" class={main_class(@content_width)}>
      <div class={content_container_class(@content_width)}>
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  defp main_class("full"), do: "allbert-page min-h-screen bg-base-100"

  defp main_class(_width),
    do: "allbert-page min-h-screen bg-base-100 px-4 py-8 sm:px-6 lg:px-8"

  defp content_container_class("full"), do: "w-full"
  defp content_container_class("wide"), do: "mx-auto max-w-6xl space-y-4"
  defp content_container_class(_width), do: "mx-auto max-w-2xl space-y-4"

  defp static_asset_version do
    :allbert_assist_web
    |> Application.spec(:vsn)
    |> to_string()
  end

  defp theme_asset_version, do: AllbertAssist.Theme.Version.stylesheet_version()

  defp root_theme_attribute do
    case setting_value("workspace.theme.mode", "system") do
      "dark" -> "dark"
      "light" -> "light"
      _theme -> nil
    end
  end

  defp root_high_contrast_attribute do
    bool_attribute(setting_value("workspace.accessibility.high_contrast", false))
  end

  defp root_reduce_motion_attribute do
    bool_attribute(setting_value("workspace.accessibility.reduce_motion", false))
  end

  defp bool_attribute(true), do: "true"
  defp bool_attribute(_value), do: nil

  defp setting_value(key, default) do
    case AllbertAssist.Settings.get(key) do
      {:ok, value} -> value
      {:error, _reason} -> default
    end
  end
end
