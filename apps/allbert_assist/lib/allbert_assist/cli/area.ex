defmodule AllbertAssist.CLI.Area do
  @moduledoc """
  The contract an area dispatcher satisfies.

  Every `{:area, module}` disposition in `AllbertAssist.CLI.Commands` resolves to
  a module exporting `dispatch/2`, and until v1.4 M12 that was convention alone —
  no behaviour, so nothing verified it. That was tolerable while every area
  compiled into the residual alongside the table that named it. It stopped being
  tolerable when a pack began contributing its own group through
  `AllbertAssist.Pack.cli_groups/0`: a contributed module is named by a row in a
  sealed projection rather than by a literal in the table, so its conformance has
  to be checkable rather than assumed.

  `dispatch/2` receives the argv remaining after the longest matching table
  prefix and the CLI context (which carries `:allbert_pack_epoch` when the
  command runs effects), and returns the output and the process exit code.
  The exit-code convention every area shares: `0` success, `1` error, `2` usage.
  """

  @callback dispatch(argv :: [String.t()], context :: map()) ::
              {String.t(), non_neg_integer()}
end
