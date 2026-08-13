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

    @doc """
    Load the applications that sit ABOVE Web, from a Mix alias, before the
    `test` task starts anything.

    v1.4 M13.2. `ProjectionProvider` reconciles metadata for every application in
    the release, and `Application.app_dir/2` raises for one that is built but not
    loaded. Artifacts and stocksage sit above Web since M13, so no owner's
    dependency closure loads them -- yet an owner whose closure reaches the
    composition host (through Web, or directly) has composition started by Mix
    *before* `test_helper.exs` runs. Composition's first attempt therefore always
    failed closed on `{:unknown_application, :stocksage}`, and the coordinator
    crash-cascaded until the helper caught up.

    Recovery worked, but not reliably: one M13 closeout census run lost the race
    and readiness never opened, failing the lane. Calling this from a `test`
    alias removes the trigger rather than tolerating the recovery, because an
    alias step is the one window before application start that
    `test_helper.exs` does not have.

    A packaged release never needed any of this -- it loads every application
    before starting any, which is why the defect is test-environment-only.

    The roster is the applications above Web, which is a property of the DAG
    rather than of any one caller, so it lives here and not in four `mix.exs`
    files. It is written out rather than derived because this runs from a Mix
    alias, before anything is loaded and before the projection can be asked --
    but a hand-maintained roster is the defect ADR 0098 catalogued, so
    `AmbientApplicationsTest` derives the same set from the projection and the
    dependency closure and fails if the two disagree.
    """
    @spec ensure_ambient_loaded!() :: :ok
    def ensure_ambient_loaded!, do: ensure_loaded!(ambient_applications())

    @doc """
    The applications above Web that `ensure_ambient_loaded!/0` loads.
    """
    @spec ambient_applications() :: [atom()]
    def ambient_applications, do: [:allbert_artifacts, :stocksage]

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

        if File.dir?(ebin), do: Code.prepend_path(ebin)
      end

      # Loaded, not merely reachable: CompiledInventory.default_applications/0
      # reads Application.loaded_applications/0 to find descriptor-bearing
      # applications, so a pack that is only on the path is invisible to it.
      #
      # v1.4 M13.2: unconditional, not only for an application this had to put on
      # the path. Being reachable and being loaded are independent, and in an
      # umbrella every sibling's ebin can already be on the path while nothing
      # has loaded it -- in which case the old code skipped the load, the walk
      # then read `Application.spec/2` as nil, and the whole transitive closure
      # below that application was silently never loaded. That is how the
      # composition owner's VM reached its own tests with Web unloaded.
      Application.load(application)

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

    Registration is `side_effects: false`. A pack whose plugin declares a
    `child_spec` -- research and browser both do -- otherwise tries to start that
    child during registration, and this runs before the composition host opens
    readiness, so it fails with `{:error, :product_not_ready}`. Staging the
    contribution and letting activation start the child is the designed path, and
    it is why the packs extracted before these two never hit this: none of them
    declared a plugin-level child.
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
            Registry.register_module(module, Keyword.put(opts, :side_effects, false))
          end)

        {:entry, %{plugin_id: plugin_id} = entry} ->
          register_absent(plugin_id, pack_plugin_ids, fn ->
            Registry.register_entry(entry, side_effects: false)
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
