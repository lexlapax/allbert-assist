ExUnit.start()

# The pack's rows drive real actions through the residual Runner and read
# settings, so they need the same environment the residual suite builds: an
# isolated Home, the composition host started, and Readiness open. This mirrors
# only the parts this pack actually depends on rather than copying the residual
# helper wholesale.
test_home =
  Path.join(
    System.tmp_dir!(),
    "stocksage-test-home-#{System.pid()}-#{System.unique_integer([:positive])}"
  )

File.rm_rf!(test_home)
System.at_exit(fn _status -> File.rm_rf(test_home) end)

Application.put_env(:allbert_assist, AllbertAssist.Paths, home: test_home)

# Umbrella recursion starts this application and its declared dependencies, so
# the composition host -- which this pack does NOT depend on, and must not,
# since composition depends on it -- is absent. Its ebin is added explicitly and
# started here, the same way the residual suite reaches upward for its own
# product owner. The dependency direction in mix.exs stays acyclic; this is a
# test-environment concern only.
# Both, not just composition: the closed projection reconciles metadata for every
# application in ProjectionProvider's list, so composition is rejected with
# {:unknown_application, :allbert_assist_web} if Web's metadata is absent.
#
# v1.4 M12: composition now depends on every pack, so its closure reaches sibling
# packs this one does not depend on and must not. The walk is transitive and read
# from each .app, so extracting another pack does not mean editing this file.
AllbertAssist.TestSupport.PackBootstrap.ensure_loaded!([
  :allbert_assist_web,
  :allbert_composition
])

# Loading is not registering. The residual ran plugin discovery while it started,
# before this file put the sibling packs on the path, so their actions sit in the
# compiled inventory claimed by no enabled plugin -- which fails composition
# closed with :invalid_registry_order. Register before starting the host.
AllbertAssist.TestSupport.PackBootstrap.ensure_registered!()

case Application.ensure_all_started(:allbert_composition) do
  {:ok, _started} -> :ok
  {:error, reason} -> raise "could not start the composition host: #{inspect(reason)}"
end

ready_deadline = System.monotonic_time(:millisecond) + 60_000

await_ready = fn await ->
  case AllbertAssist.Pack.Readiness.status(timeout: 1_000) do
    {:ok, %{phase: :ready}} ->
      :ok

    _other ->
      if System.monotonic_time(:millisecond) < ready_deadline do
        Process.sleep(25)
        await.(await)
      else
        raise "Pack readiness did not open after the stocksage bootstrap"
      end
  end
end

await_ready.(await_ready)
Ecto.Adapters.SQL.Sandbox.mode(AllbertAssist.Repo, :manual)
