defmodule Mix.Tasks.Allbert.Marketplace do
  @moduledoc """
  Operate Marketplace Lite.

  M2 ships the minimal operator-validation commands. M3 completes the
  show/verify/mirror/doctor CLI surface after the full seed catalog lands.

  ## Usage

      mix allbert.marketplace list [--kind KIND]
      mix allbert.marketplace show ENTRY_ID
      mix allbert.marketplace install ENTRY_ID [--version VERSION]
      mix allbert.marketplace installed
      mix allbert.marketplace rollback ENTRY_ID
      mix allbert.marketplace verify ENTRY_ID
      mix allbert.marketplace mirror
      mix allbert.marketplace doctor

  The dispatch logic is shared with the packaged `allbert admin marketplace`
  command (`AllbertAssist.CLI.Areas.Marketplace`); this task is a thin Mix-shell
  wrapper.
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Operate Marketplace Lite"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.Marketplace, args)
  end
end
