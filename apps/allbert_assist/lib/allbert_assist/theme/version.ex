defmodule AllbertAssist.Theme.Version do
  @moduledoc """
  Cache-busting version for v0.35 local appearance stylesheets.
  """

  alias AllbertAssist.Settings
  alias AllbertAssist.Theme.Status

  @spec stylesheet_version() :: String.t()
  def stylesheet_version do
    status = Status.summary()

    [
      setting("workspace.theme.mode"),
      setting("workspace.theme.active"),
      setting("workspace.theme.snippets_enabled"),
      setting("workspace.theme.enabled_snippets"),
      setting("workspace.layout.override_enabled"),
      status.token.basename,
      status.token.fingerprint,
      status.token.mtime,
      snippet_versions(status.snippets.items),
      status.layout.fingerprint,
      status.layout.mtime
    ]
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  rescue
    _exception -> "unavailable"
  end

  defp snippet_versions(items) do
    Enum.map(items, &{&1.basename, &1.fingerprint, &1.mtime})
  end

  defp setting(key) do
    case Settings.get(key) do
      {:ok, value} -> value
      _other -> nil
    end
  end
end
