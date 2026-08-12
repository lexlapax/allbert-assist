# Kept in `lib/` under a test-env guard for the same reason as
# `AllbertAssist.TestSupport.ReadyEffectContext`: a sibling application can only
# reach a module that belongs to a started application's module list, and a
# `test/support` module does not.
#
# v1.4 M12 made this necessary. An owner lane runs its suite from its own
# application directory, so the code path Mix builds is that application's
# dependency closure and nothing else. Every pack's test helper nonetheless
# starts the composition host, which depends on EVERY pack -- and the residual's
# helper loads each pack to keep the compiled action catalog contiguous. Both
# directions reach applications the running one does not depend on, which is a
# test-environment concern only: the dependency direction in every mix.exs stays
# acyclic.
#
# Three pack helpers plus the residual's needed the identical walk, so it lives
# once here rather than four times in four `test_helper.exs` files.
if Mix.env() == :test do
  defmodule AllbertAssist.TestSupport.PackBootstrap do
    @moduledoc false

    alias AllbertAssist.App.Bootstrap
    alias AllbertAssist.Plugin.Discovery
    alias AllbertAssist.Plugin.Registry

    @doc """
    Put `applications` and everything they need on the code path, and load them.

    Walks each `.app`'s own `applications` list transitively rather than taking a
    hardcoded roster, because resolving only the direct level just moves the same
    failure one step down: `allbert_email` needs gen_smtp, and gen_smtp needs
    ranch. Reading the closure from the artifacts means adding a dependency to a
    pack never means editing a test helper.

    Deliberately NOT a blanket prepend of every built ebin. That would also
    satisfy a dependency an application forgot to declare, hiding in the test VM
    exactly the mistake the release boundary checks exist to catch. Only
    applications the current code path cannot already resolve are added.
    """
    @spec ensure_loaded!([atom()]) :: :ok
    def ensure_loaded!(applications) when is_list(applications) do
      # The accumulator is the visited set that keeps the walk from looping on a
      # dependency cycle; it is threaded, not discarded, so bind it rather than
      # leaving a bare Enum call whose return looks incidental.
      _visited = Enum.reduce(applications, MapSet.new(), &walk(&1, &2))
      :ok
    end

    defp walk(application, seen) do
      if MapSet.member?(seen, application) do
        seen
      else
        seen = MapSet.put(seen, application)
        add(application)

        Enum.reduce(Application.spec(application, :applications) || [], seen, &walk(&1, &2))
      end
    end

    defp add(application) do
      if :code.lib_dir(application) == {:error, :bad_name} do
        ebin = Path.join([Mix.Project.build_path(), "lib", Atom.to_string(application), "ebin"])

        if File.dir?(ebin) do
          Code.prepend_path(ebin)
          # Loaded, not merely reachable: CompiledInventory.default_applications/0
          # reads Application.loaded_applications/0 to find descriptor-bearing
          # applications, so a pack that is only on the path is invisible to it.
          Application.load(application)
        end
      end

      :ok
    end

    @doc """
    Register every extracted pack's plugin, and retry the App registrations that
    deferred because of it.

    Loading a pack is not the same as registering it. The residual runs plugin
    discovery while IT starts, and in an owner-scoped run the sibling packs are
    not loaded until this file executes -- so their manifests were not visible to
    that pass. Their actions are nonetheless in the compiled inventory, claimed
    by no enabled plugin, which fails composition closed with
    `:invalid_registry_order` on the `actions` field. That is exactly the hole
    `Plugin.Discovery`'s extracted-manifest support exists to prevent.

    The pack roster is derived from the loaded applications that declare
    `allbert_pack`, not listed here: extracting another pack must not mean
    editing a test helper, which is the hand-maintained-roster defect ADR 0098
    catalogued and M1 deleted.
    """
    @spec ensure_registered!() :: :ok
    def ensure_registered! do
      pack_plugin_ids = extracted_pack_plugin_ids()

      Discovery.discover()
      |> Enum.each(fn
        # Discovery yields a pack either as a compiled module -- its Plugin
        # module is in the loaded application's module list -- or as a manifest
        # entry read from the application's priv. Both are handled rather than
        # assuming one.
        {:module, module, opts} ->
          register_absent(module.plugin_id(), pack_plugin_ids, fn ->
            Registry.register_module(module, opts)
          end)

        {:entry, %{plugin_id: plugin_id} = entry} ->
          register_absent(plugin_id, pack_plugin_ids, fn ->
            Registry.register_entry(entry)
          end)

        _other ->
          :ok
      end)

      # Every App declaring a pack-owned action deferred while the catalog was
      # incomplete -- CoreApp and AllbertBrowser.App among them, not only the
      # packs' own. Before v1.4 M9 those failures were dropped silently and the
      # VM ran with an incomplete App registry.
      {:ok, []} = Bootstrap.retry_pending()

      :ok
    end

    defp register_absent(plugin_id, pack_plugin_ids, register) do
      if plugin_id in pack_plugin_ids and
           not match?({:ok, _entry}, Registry.lookup(plugin_id)) do
        {:ok, ^plugin_id} = register.()
      end

      :ok
    end

    defp extracted_pack_plugin_ids do
      Application.loaded_applications()
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&(Application.fetch_env(&1, :allbert_pack) != :error))
      |> Enum.flat_map(&manifest_plugin_id/1)
    end

    defp manifest_plugin_id(application) do
      path = Application.app_dir(application, "priv/allbert_plugin.json")

      with true <- File.regular?(path),
           {:ok, bytes} <- File.read(path),
           {:ok, %{"plugin_id" => plugin_id}} <- Jason.decode(bytes) do
        [plugin_id]
      else
        _absent -> []
      end
    rescue
      ArgumentError -> []
    end
  end
end
