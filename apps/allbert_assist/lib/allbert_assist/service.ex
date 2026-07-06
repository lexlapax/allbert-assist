defmodule AllbertAssist.Service do
  @moduledoc """
  Per-user OS service management for `allbert serve` (v0.62 M5, Locked
  Decision 11): macOS `launchd` user agents (`launchctl bootstrap gui/$UID`,
  never the deprecated `load`) and Linux `systemd --user` units (+ offered
  `enable-linger`). System units are out of scope — user units keep the daemon
  in the user session where the OS vault lives. `WorkingDirectory` is pinned to
  Allbert Home so the cwd-derived security-scope defaults do not widen.

  This module renders the unit/plist and returns the exact commands; the
  effectful install/uninstall run through the registered service actions
  (confirmation-floored), never an off-spine shell path.
  """

  alias AllbertAssist.Paths

  @label "com.lexlapax.allbert"

  @doc "The OS this build targets for service management."
  @spec platform() :: :launchd | :systemd | :unsupported
  def platform do
    case :os.type() do
      {:unix, :darwin} -> :launchd
      {:unix, _linux} -> :systemd
      _other -> :unsupported
    end
  end

  @doc "The service unit/plist path for the current user."
  @spec unit_path() :: String.t()
  def unit_path do
    case platform() do
      :launchd -> Path.expand("~/Library/LaunchAgents/#{@label}.plist")
      :systemd -> Path.expand("~/.config/systemd/user/allbert.service")
      :unsupported -> ""
    end
  end

  @doc "Render the unit/plist content for a given `allbert` binary path."
  @spec render_unit(String.t()) :: String.t()
  def render_unit(binary) do
    home = Paths.home()

    case platform() do
      :launchd -> launchd_plist(binary, home)
      :systemd -> systemd_unit(binary, home)
      :unsupported -> ""
    end
  end

  @doc """
  The command sequence to install + start the user service. Returns a list of
  `{cmd, args}` the install action executes in order (after writing the unit).
  """
  @spec install_commands() :: [{String.t(), [String.t()]}]
  def install_commands do
    case platform() do
      :launchd ->
        uid = System.get_env("UID") || uid_from_id()
        [{"launchctl", ["bootstrap", "gui/#{uid}", unit_path()]}]

      :systemd ->
        [
          {"systemctl", ["--user", "daemon-reload"]},
          {"systemctl", ["--user", "enable", "--now", "allbert.service"]}
        ]

      :unsupported ->
        []
    end
  end

  @doc "The command sequence to stop + uninstall the user service."
  @spec uninstall_commands() :: [{String.t(), [String.t()]}]
  def uninstall_commands do
    case platform() do
      :launchd ->
        uid = System.get_env("UID") || uid_from_id()
        [{"launchctl", ["bootout", "gui/#{uid}/#{@label}"]}]

      :systemd ->
        [{"systemctl", ["--user", "disable", "--now", "allbert.service"]}]

      :unsupported ->
        []
    end
  end

  @doc """
  Probe whether a live user service manager is reachable (Linux user-bus /
  WSL2 flakiness; macOS launchd is always present for a login session). When
  absent, callers degrade to documented foreground `allbert serve`.
  """
  @spec manager_available?() :: boolean()
  def manager_available? do
    case platform() do
      :launchd ->
        true

      :systemd ->
        System.get_env("XDG_RUNTIME_DIR") not in [nil, ""] and
          match?({_, 0}, safe_cmd("systemctl", ["--user", "is-system-running"]))

      :unsupported ->
        false
    end
  end

  @spec log_path() :: String.t()
  def log_path do
    case platform() do
      :launchd -> Path.expand("~/Library/Logs/allbert/allbert.log")
      _other -> Path.join([Paths.home(), "log", "allbert.log"])
    end
  end

  # -- templates -------------------------------------------------------------

  defp launchd_plist(binary, home) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>#{@label}</string>
      <key>ProgramArguments</key>
      <array><string>#{binary}</string><string>serve</string></array>
      <key>WorkingDirectory</key><string>#{home}</string>
      <key>EnvironmentVariables</key>
      <dict>
        <key>ALLBERT_HOME</key><string>#{home}</string>
        <key>PHX_SERVER</key><string>true</string>
        <key>SHELL</key><string>/bin/sh</string>
      </dict>
      <key>KeepAlive</key><true/>
      <key>RunAtLoad</key><true/>
      <key>StandardOutPath</key><string>#{log_path()}</string>
      <key>StandardErrorPath</key><string>#{log_path()}</string>
    </dict>
    </plist>
    """
  end

  defp systemd_unit(binary, home) do
    """
    [Unit]
    Description=Allbert local assistant runtime
    After=network.target

    [Service]
    Type=simple
    ExecStart=#{binary} serve
    WorkingDirectory=#{home}
    Environment=ALLBERT_HOME=#{home}
    Environment=PHX_SERVER=true
    Environment=SHELL=/bin/sh
    Restart=on-failure

    [Install]
    WantedBy=default.target
    """
  end

  defp uid_from_id do
    case safe_cmd("id", ["-u"]) do
      {out, 0} -> String.trim(out)
      _error -> "501"
    end
  end

  defp safe_cmd(cmd, args) do
    System.cmd(cmd, args, stderr_to_stdout: true)
  rescue
    _error -> {"", 1}
  end
end
