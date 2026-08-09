ExUnit.start()

# Umbrella recursion runs each application's tests with only that application
# and its declared dependencies started, so a kernel test never sees the pack —
# which is the boundary working, not a gap. The concerns relocated at M8 still
# reach their providers through kernel contracts, so the kernel test
# environment binds its own set rather than borrowing composition's.
#
# The set is the fail-closed test provider: no settings, no memberships, an
# empty overlay. A row that needs a value states it through
# `TestProviders.stub_settings!/1` or `stub_home_roots!/1`, which carry the rest
# of the binding over unchanged.
barrier = spawn(fn -> Process.sleep(:infinity) end)

{:ok, _binding} =
  AllbertAssist.Kernel.Contract.Owner.bind(
    AllbertAssist.Kernel.Contract.TestProviders.complete(),
    "kernel-test-environment",
    barrier
  )
