import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Headless singleton behind the Cloud plugin.
//
// A bar widget is instantiated once per monitor, so the polling lives here --
// the shell mounts exactly one service per plugin, and a two-monitor setup
// should not double the work.
//
// The service deliberately owns no mounts. `rclone mount` runs under systemd
// (see bin/omarchy-cloud-mount), because a mount parented to the shell process
// would be torn down by `omarchy restart shell` and by every plugin
// hot-reload during development, taking any open file with it. Everything
// here is therefore either a read of local state or a short-lived control
// command.
Item {
  id: root

  // Injected by the shell.
  property var shell: null
  property var settings: ({})

  // ---------------------------------------------------------------- state

  property bool rcloneInstalled: true
  property string rcloneVersion: ""
  property string mountRoot: ""
  property var remotes: []
  property bool refreshing: false
  property string lastError: ""
  property string actionStatus: ""

  readonly property string aggregateState: Model.aggregateState(remotes)
  readonly property string barSummary: Model.barSummary(remotes)
  readonly property bool busy: statusProcess.running || controlProcess.running

  // ---------------------------------------------------------------- settings

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  readonly property string configuredRoot: String(setting("mountRoot", "~/Cloud"))
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 15, 5, 300)
  readonly property int quotaIntervalMin: intSetting("quotaIntervalMin", 20, 5, 240)
  readonly property string vfsCacheMode: String(setting("vfsCacheMode", "full"))
  readonly property int cacheMaxSizeGB: intSetting("cacheMaxSizeGB", 8, 1, 512)

  // ---------------------------------------------------------------- paths
  //
  // The shell injects `settings` into widgets but not the plugin's own
  // directory, and first-party plugins cheat by reading OMARCHY_PATH -- which
  // resolves to the packaged tree, not here. Qt.resolvedUrl is relative to
  // this file, so it works wherever the plugin is installed.
  function scriptPath(name) {
    return Qt.resolvedUrl("bin/" + name).toString().replace(/^file:\/\//, "")
  }

  readonly property string statusScript: scriptPath("omarchy-cloud-status")
  readonly property string mountScript: scriptPath("omarchy-cloud-mount")
  readonly property string connectScript: scriptPath("omarchy-cloud-connect")

  // ---------------------------------------------------------------- reading

  property bool _statusIncludesQuota: false
  property bool _quotaPending: false

  function refresh(withQuota) {
    if (statusProcess.running) {
      // A cheap poll may already be running when the slow quota timer fires.
      // Remember that request; otherwise two aligned repeating timers can
      // starve quota refreshes forever.
      if (withQuota === true && !_statusIncludesQuota) _quotaPending = true
      return
    }
    var includeQuota = withQuota === true || _quotaPending
    _quotaPending = false
    _statusIncludesQuota = includeQuota
    refreshing = true

    var args = [statusScript, "--root", configuredRoot]
    if (includeQuota) args.push("--with-quota")
    args.push("--quota-age", String(quotaIntervalMin * 60))

    statusProcess.command = ["python3"].concat(args)
    statusProcess.running = true
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    if (!parsed.ok) {
      lastError = String(parsed.error || "Could not read cloud status")
      return
    }
    rcloneInstalled = parsed.rcloneInstalled === true
    rcloneVersion = String(parsed.rcloneVersion || "")
    mountRoot = String(parsed.mountRoot || "")
    remotes = parsed.remotes || []
    lastError = ""
  }

  // ---------------------------------------------------------------- control

  // Reflect a mount/unmount immediately rather than waiting for the next poll:
  // systemd takes a beat to settle, and a toggle that appears to do nothing
  // for two seconds reads as broken. The poll corrects any optimism.
  function setPending(name, state) {
    var next = []
    for (var i = 0; i < remotes.length; i++) {
      var row = remotes[i]
      if (row.name === name) {
        var copy = {}
        for (var key in row) copy[key] = row[key]
        copy.state = state
        next.push(copy)
      } else {
        next.push(row)
      }
    }
    remotes = next
  }

  function runControl(args, failureMessage) {
    if (controlProcess.running) return false
    controlProcess.failureMessage = failureMessage || "Command failed"
    controlProcess.command = ["bash", mountScript].concat(args)
    controlProcess.running = true
    return true
  }

  function mount(name) {
    setPending(name, "mounting")
    runControl(["start", name], "Could not mount " + name)
  }

  function unmount(name) {
    setPending(name, "stopped")
    runControl(["stop", name], "Could not unmount " + name)
  }

  function toggleMount(remote) {
    if (!remote || !remote.name) return
    if (remote.state === "mounted" || remote.state === "mounting") unmount(remote.name)
    else if (remote.state !== "needs-auth") mount(remote.name)
  }

  function setAutoMount(remote, enabled) {
    if (!remote || !remote.name) return
    runControl([enabled ? "enable" : "disable", remote.name],
               "Could not change login setting for " + remote.name)
  }

  // Pushes the plugin's settings to disk for systemd's benefit. Units start at
  // login with no access to shell.json, so the mount flags have to be readable
  // from a file the unit can source.
  function pushSettings() {
    if (controlProcess.running) return
    runControl(["settings",
                "MOUNT_ROOT=" + configuredRoot,
                "VFS_CACHE_MODE=" + vfsCacheMode,
                "CACHE_MAX_SIZE_GB=" + String(cacheMaxSizeGB)],
               "Could not save mount settings")
  }

  // ---------------------------------------------------------------- actions

  function openInFiles(remote) {
    if (!remote || !remote.mountPath) return
    Quickshell.execDetached(["uwsm-app", "--", "nautilus", Model.fileUri(remote.mountPath)])
  }

  readonly property string termScript: scriptPath("omarchy-cloud-term")

  // The interactive scripts open a browser for OAuth and ask questions, so
  // they run in a real terminal rather than being driven headlessly from here.
  function runInTerminal(script, args) {
    var command = [termScript, script]
    if (args) command = command.concat(args)
    Quickshell.execDetached(command)
    settleTimer.restart()
  }

  function connectService() {
    actionStatus = "Opening setup…"
    actionStatusTimer.restart()
    runInTerminal("omarchy-cloud-connect", [])
  }

  function configure(remote) {
    if (!remote || !remote.name) return
    actionStatus = "Opening settings…"
    actionStatusTimer.restart()
    runInTerminal("omarchy-cloud-configure", [remote.name])
  }

  function reconnect(remote) {
    if (!remote || !remote.name) return
    actionStatus = "Opening sign-in…"
    actionStatusTimer.restart()
    runInTerminal("omarchy-cloud-reconnect", [remote.name])
  }

  function installRclone() {
    actionStatus = "Installing rclone…"
    actionStatusTimer.restart()
    runInTerminal("omarchy-cloud-install", [])
  }

  // ---------------------------------------------------------------- timers

  Timer {
    // Cheap: local files and one batched systemctl call, no network.
    id: pollTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  Timer {
    // Expensive: one network round trip per mounted remote, so it runs on its
    // own slow schedule and the helper caches the answer on disk besides.
    id: quotaTimer
    interval: root.quotaIntervalMin * 60 * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh(true)
  }

  Timer {
    // After an action that happens outside the shell (the wizard, a sign-in),
    // poll a few times so the panel catches up without waiting a full cycle.
    id: settleTimer
    property int ticks: 0
    interval: 3000
    repeat: true
    running: false
    onTriggered: {
      ticks += 1
      root.refresh(false)
      if (ticks >= 8) {
        ticks = 0
        settleTimer.running = false
      }
    }
    onRunningChanged: if (running) ticks = 0
  }

  Timer {
    id: actionStatusTimer
    interval: 2600
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Timer {
    // Settings arrive one property at a time as the shell applies them; wait
    // for the burst to finish before writing the file and regenerating the
    // unit.
    id: settingsDebounce
    interval: 800
    repeat: false
    onTriggered: root.pushSettings()
  }

  onConfiguredRootChanged: settingsDebounce.restart()
  onVfsCacheModeChanged: settingsDebounce.restart()
  onCacheMaxSizeGBChanged: settingsDebounce.restart()

  // Write the settings file once at startup too. Leaving every default
  // untouched changes no property, so the handlers above would never fire and
  // systemd would be left with no settings file at all -- which works only for
  // as long as the shell defaults and the script defaults agree.
  Component.onCompleted: settingsDebounce.restart()

  // ---------------------------------------------------------------- processes

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    stderr: StdioCollector { id: statusErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      if (exitCode === 0) root.applyStatus(statusOut.text)
      else root.lastError = String(statusErr.text || "Could not read cloud status").substring(0, 160)
      root._statusIncludesQuota = false
      if (root._quotaPending) Qt.callLater(function() { root.refresh(true) })
    }
  }

  Process {
    id: controlProcess
    property string failureMessage: ""
    running: false
    command: []
    stdout: StdioCollector { id: controlOut; waitForEnd: true }
    stderr: StdioCollector { id: controlErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        var reason = String(controlErr.text || controlOut.text || "").trim()
        root.lastError = (failureMessage + (reason ? ": " + reason : "")).substring(0, 200)
        root.actionStatus = ""
      } else {
        root.lastError = ""
      }
      // Either way, find out what actually happened.
      settleTimer.restart()
    }
  }
}
