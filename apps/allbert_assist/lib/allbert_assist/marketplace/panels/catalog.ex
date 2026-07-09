defmodule AllbertAssist.Marketplace.Panels.Catalog do
  @moduledoc """
  Declarative workspace panel for Marketplace Lite catalog browsing.

  The panel is metadata-only. It reads through registered marketplace actions
  and emits action-button bindings back to registered actions.
  """

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Runtime.Response
  alias AllbertAssist.Surface.ActionBinding
  alias AllbertAssist.Surface.Node

  @kind_order ["skill", "template", "plugin_index"]
  @kind_labels %{
    "skill" => "Skills",
    "template" => "Templates",
    "plugin_index" => "Plugin Index"
  }
  @installable_kinds ["skill", "template"]

  @spec node(map()) :: Node.t()
  def node(context \\ %{}) when is_map(context) do
    if Application.get_env(:allbert_assist, :cli_oneshot?, false) do
      # F4: a one-off CLI command never renders the marketplace panel; skip the two
      # action-pipeline runs at boot and emit the same-id empty catalog node (the web
      # re-renders the real catalog live under `serve`).
      catalog_node([], [])
    else
      with {:ok, entries} <- entries(context),
           {:ok, installed} <- installed(context) do
        catalog_node(entries, installed)
      else
        {:error, reason} -> error_node(reason)
      end
    end
  end

  defp entries(context) do
    {:ok, response} = action("list_marketplace_entries", %{}, context)

    case Response.status(response) do
      :completed -> {:ok, response.result.entries}
      _status -> {:error, response_error(response)}
    end
  end

  defp installed(context) do
    {:ok, response} = action("list_installed_marketplace_bundles", %{}, context)

    case Response.status(response) do
      :completed -> {:ok, response.result.installed}
      _status -> {:error, response_error(response)}
    end
  end

  defp catalog_node(entries, installed) do
    %Node{
      id: "marketplace-catalog",
      component: :panel,
      props: %{
        title: "Marketplace Catalog",
        body: "#{length(entries)} reviewed entries; #{length(installed)} installed."
      },
      children: group_nodes(entries, installed)
    }
  end

  defp group_nodes(entries, installed) do
    installed_by_id = Map.new(installed, &{&1["entry_id"], &1})

    @kind_order
    |> Enum.flat_map(fn kind ->
      entries
      |> Enum.filter(&(&1["kind"] == kind))
      |> case do
        [] -> []
        kind_entries -> [group_node(kind, kind_entries, installed_by_id)]
      end
    end)
  end

  defp group_node(kind, entries, installed_by_id) do
    %Node{
      id: "marketplace-group-#{kind}",
      component: :section,
      props: %{
        title: Map.fetch!(@kind_labels, kind),
        body: group_body(kind, entries)
      },
      children: Enum.flat_map(entries, &entry_nodes(&1, Map.get(installed_by_id, &1["id"])))
    }
  end

  defp entry_nodes(entry, installed) do
    [
      entry_card(entry, installed),
      button_row(entry, installed)
    ]
  end

  defp entry_card(entry, installed) do
    %Node{
      id: "marketplace-entry-#{entry_key(entry["id"])}",
      component: :settings_card,
      props: %{
        title: entry["name"],
        body: entry_body(entry),
        status: entry_status(entry, installed),
        external_id: entry["id"]
      }
    }
  end

  defp button_row(entry, installed) do
    %Node{
      id: "marketplace-entry-#{entry_key(entry["id"])}-actions",
      component: :row,
      props: %{title: "#{entry["name"]} actions"},
      children: action_buttons(entry, installed)
    }
  end

  defp action_buttons(entry, installed) do
    [
      action_button(entry, "Inspect", "inspect_marketplace_entry"),
      action_button(entry, "Verify Hash", "verify_marketplace_bundle_hash")
    ] ++ install_buttons(entry, installed)
  end

  defp install_buttons(%{"kind" => kind} = entry, nil) when kind in @installable_kinds do
    [action_button(entry, "Install", "install_marketplace_bundle")]
  end

  defp install_buttons(%{"kind" => kind} = entry, _installed) when kind in @installable_kinds do
    [action_button(entry, "Rollback", "rollback_marketplace_install")]
  end

  defp install_buttons(_entry, _installed), do: []

  defp action_button(entry, title, action_name) do
    %Node{
      id: "marketplace-#{entry_key(entry["id"])}-#{action_key(action_name)}",
      component: :action_button,
      props: %{
        title: title,
        phx_click: "run_marketplace_action",
        action_name: action_name,
        entry_id: entry["id"]
      },
      bindings: [
        %ActionBinding{
          action_name: action_name
        }
      ]
    }
  end

  defp error_node(reason) do
    %Node{
      id: "marketplace-catalog",
      component: :panel,
      props: %{
        title: "Marketplace Catalog",
        body: "Marketplace catalog could not be loaded."
      },
      children: [
        %Node{
          id: "marketplace-catalog-error",
          component: :empty_state,
          props: %{
            title: "Catalog unavailable",
            body: inspect(reason)
          }
        }
      ]
    }
  end

  defp action(action_name, params, context) do
    Runner.run(action_name, params, action_context(context))
  end

  defp action_context(context) do
    %{
      actor: Map.get(context, :user_id, "local"),
      user_id: Map.get(context, :user_id, "local"),
      operator_id: Map.get(context, :operator_id, Map.get(context, :user_id, "local")),
      thread_id: Map.get(context, :thread_id),
      session_id: Map.get(context, :session_id),
      active_app: Map.get(context, :active_app, :allbert),
      channel: :workspace_panel,
      surface: "marketplace_catalog_panel"
    }
  end

  defp response_error(%{error: error}), do: error
  defp response_error(%{message: message}), do: message

  defp group_body("plugin_index", entries) do
    "#{length(entries)} browse-only reviewed-source descriptor."
  end

  defp group_body(_kind, entries), do: "#{length(entries)} installable reviewed entry."

  defp entry_body(entry) do
    "#{entry["description"]} Version #{entry["version"]}; #{entry["bundle_hash"]}."
  end

  defp entry_status(%{"kind" => "plugin_index"}, _installed), do: "browse_only"
  defp entry_status(_entry, nil), do: "available"
  defp entry_status(_entry, _installed), do: "installed"

  defp safe_id(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-")
    |> String.trim("-")
  end

  defp entry_key(entry_id), do: entry_id |> safe_id() |> String.slice(0, 36)

  defp action_key("inspect_marketplace_entry"), do: "inspect"
  defp action_key("verify_marketplace_bundle_hash"), do: "verify"
  defp action_key("install_marketplace_bundle"), do: "install"
  defp action_key("rollback_marketplace_install"), do: "rollback"
  defp action_key(action_name), do: action_name |> safe_id() |> String.slice(0, 12)
end
