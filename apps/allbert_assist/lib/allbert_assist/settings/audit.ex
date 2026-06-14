defmodule AllbertAssist.Settings.Audit do
  @moduledoc """
  Append-only markdown audit records for Settings Central writes.
  """

  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Settings.Store

  def audit_root, do: Path.join(Store.root(), "audit")

  def audit_path(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)
    Path.join(audit_root(), "#{Calendar.strftime(now, "%Y-%m")}.md")
  end

  def append_setting(key, old_value, new_value, context \\ %{}) do
    append(%{
      key: key,
      old: Secrets.redact(key, old_value),
      new: Secrets.redact(key, new_value),
      context: context,
      permission: context_value(context, :permission_decision, :allowed),
      validation: :ok
    })
  end

  def append_secret(secret_ref, old_status, new_status, context \\ %{}) do
    append(%{
      key: secret_ref,
      old: old_status,
      new: new_status,
      context: context,
      permission: context_value(context, :permission_decision, :allowed),
      validation: :ok
    })
  end

  def append_secret_fetch(secret_ref, context \\ %{}) do
    append(%{
      key: secret_ref,
      old: :configured,
      new: :fetched,
      context: context,
      permission: context_value(context, :permission_decision, :allowed),
      validation: :ok
    })
  end

  def append(entry) when is_map(entry) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    path = audit_path(now)
    File.mkdir_p!(Path.dirname(path))

    case writer().(path, render_entry(entry, now)) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:audit_write_failed, reason}}
    end
  rescue
    exception ->
      {:error, {:audit_write_failed, {exception.__struct__, Exception.message(exception)}}}
  end

  defp writer do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:writer, &File.write(&1, &2, [:append]))
  end

  defp render_entry(entry, now) do
    context = Map.fetch!(entry, :context)

    """

    ## #{DateTime.to_iso8601(now)} #{entry.key}

    - actor: #{context_value(context, :actor, "local")}
    - channel: #{context_value(context, :channel, "unknown")}
    - source_signal_id: #{context_value(context, :source_signal_id, "none")}
    - permission: #{permission_text(entry.permission)}
    - validation: #{entry.validation}
    - old: #{value_text(entry.old)}
    - new: #{value_text(entry.new)}
    - audit_version: 1
    """
  end

  defp context_value(context, key, default) do
    context
    |> Map.get(key)
    |> Kernel.||(Map.get(context, Atom.to_string(key)))
    |> Kernel.||(default)
  end

  defp permission_text(%{decision: decision}), do: decision
  defp permission_text(%{"decision" => decision}), do: decision
  defp permission_text(permission), do: permission

  defp value_text(value) when is_atom(value), do: Atom.to_string(value)
  defp value_text(value) when is_binary(value), do: value
  defp value_text(value), do: inspect(value)
end
