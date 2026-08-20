.pragma library

// Pure helpers shared by the service, the bar widget and the panel, so the
// three cannot drift on what a state is called or how a size is written.

// Nerd Font (Material Design) glyphs.
var GLYPH_CLOUD    = "󰅟"
var GLYPH_MOUNTED  = "󰅠"
var GLYPH_MOUNTING = "󰘿"
var GLYPH_STOPPED  = "󰅤"
var GLYPH_ALERT    = "󰧠"
var GLYPH_ADD      = "󰐕"
var GLYPH_OPEN     = "󰏌"
var GLYPH_SETTINGS = "󰒓"
var GLYPH_RECONNECT = "󰑓"

// Worst-first. The bar shows one icon for everything, so it has to show the
// state that most deserves attention rather than the most common one.
var SEVERITY = ["failed", "needs-auth", "mounting", "stopped", "mounted"]

function parseStatus(raw) {
  try {
    var parsed = JSON.parse(String(raw || ""))
    if (!parsed || typeof parsed !== "object") return { ok: false, error: "Bad status output" }
    return parsed
  } catch (e) {
    return { ok: false, error: "Could not read cloud status" }
  }
}

function formatBytes(bytes) {
  var n = Number(bytes || 0)
  if (!isFinite(n) || n <= 0) return "0 B"
  var units = ["B", "KB", "MB", "GB", "TB", "PB"]
  var index = 0
  while (n >= 1024 && index < units.length - 1) {
    n /= 1024
    index += 1
  }
  // Bytes and kilobytes never need a decimal; above that one is plenty.
  var decimals = index <= 1 ? 0 : (n < 10 ? 1 : 0)
  return n.toFixed(decimals) + " " + units[index]
}

function usageText(remote) {
  if (!remote || !remote.quotaKnown) return ""
  return formatBytes(remote.usedBytes) + " of " + formatBytes(remote.totalBytes)
}

function usageFraction(remote) {
  if (!remote || !remote.quotaKnown || !remote.totalBytes) return 0
  var fraction = Number(remote.usedBytes) / Number(remote.totalBytes)
  return Math.max(0, Math.min(1, fraction))
}

function stateLabel(state) {
  switch (state) {
    case "mounted":    return "Mounted"
    case "mounting":   return "Mounting"
    case "failed":     return "Failed"
    case "needs-auth": return "Sign in"
    default:           return "Off"
  }
}

function stateGlyph(state) {
  switch (state) {
    case "mounted":    return GLYPH_MOUNTED
    case "mounting":   return GLYPH_MOUNTING
    case "failed":     return GLYPH_ALERT
    case "needs-auth": return GLYPH_ALERT
    default:           return GLYPH_STOPPED
  }
}

// What the row's subtitle says, in the order a person would want it: the
// problem if there is one, then the useful fact, then where it lives.
function rowDetail(remote) {
  if (!remote) return ""
  if (remote.state === "failed" && remote.detail) return String(remote.detail)
  if (remote.state === "needs-auth") return "Sign-in needed"
  if (remote.state === "mounted") {
    var usage = usageText(remote)
    return usage !== "" ? usage : String(remote.mountPath || "")
  }
  if (remote.state === "mounting") return "Starting…"
  return remote.autoMount ? "Not mounted" : "Not mounted at login"
}

function aggregateState(remotes) {
  if (!remotes || remotes.length === 0) return "empty"
  for (var i = 0; i < SEVERITY.length; i++) {
    for (var j = 0; j < remotes.length; j++) {
      if (remotes[j].state === SEVERITY[i]) return SEVERITY[i]
    }
  }
  return "stopped"
}

function mountedCount(remotes) {
  if (!remotes) return 0
  var count = 0
  for (var i = 0; i < remotes.length; i++) if (remotes[i].state === "mounted") count += 1
  return count
}

function barSummary(remotes) {
  if (!remotes || remotes.length === 0) return ""
  return mountedCount(remotes) + "/" + remotes.length
}

// Percent-encode each path segment so names with spaces survive the handoff
// to the file manager.
function fileUri(path) {
  var parts = String(path || "").split("/")
  for (var i = 0; i < parts.length; i++) parts[i] = encodeURIComponent(parts[i])
  return "file://" + parts.join("/")
}
