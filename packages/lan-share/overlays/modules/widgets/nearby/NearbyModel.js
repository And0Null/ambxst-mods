// NearbyModel.js — pure helpers for and0null.nearby.
//
// Subset port of oma.nearby 1.1.2 Model.js: discovery peer shaping,
// incoming-transfer queue shaping, text-send command shaping, Downloads
// collision-suffix helper, and SemVer version-gate helpers.
//
// Deliberately excluded from the port (v1.0 scope):
// - shell.json bar-entry helpers (barEntry, promotion, receiverEnabledIn):
//   persistence lives in StateService key `nearby.receiverEnabled` with
//   default OFF, enforced by NearbyService (PR2), never by this module.
// - PIN flows, updater helpers (helperUpdateAvailable,
//   helperVersionMatches exact-match, manifest readers): no PIN, no
//   updater UI in v1.0/v1.1. `minHelperVersion` is a QML const in
//   NearbyService and is checked here only via `helperSatisfies`.
// - UI cosmetics (iconFor, formatBytes): the card owns its presentation.
//   (v1.1 adds file-send shaping below; shell.json bar-entry helpers stay
//   excluded for the same reason as above.)
//
// No QML signals in this file. All functions are pure and Node-testable.
function parseLine(line) {
  try { return JSON.parse(String(line || "")) } catch (e) { return null }
}

function upsertDevice(devices, device, nowMs) {
  if (!device || !device.fingerprint || !device.alias) return devices || []
  var seen = (typeof nowMs === "number" && isFinite(nowMs)) ? nowMs : Date.now()
  var next = (devices || []).slice()
  var found = -1
  for (var i = 0; i < next.length; i++) if (next[i].fingerprint === device.fingerprint) { found = i; break }
  var row = {
    alias: String(device.alias), version: String(device.version || "2.1"), deviceModel: String(device.deviceModel || ""),
    deviceType: String(device.deviceType || "desktop"), fingerprint: String(device.fingerprint),
    port: Number(device.port || 53317), protocol: String(device.protocol || "https"),
    download: device.download === true, ip: String(device.ip || ""), lastSeen: seen
  }
  if (found < 0) next.push(row); else next[found] = row
  next.sort(function(a, b) { return a.alias.localeCompare(b.alias) })
  return next
}

function snapshotDevices(snapshot, nowMs) {
  var seen = (typeof nowMs === "number" && isFinite(nowMs)) ? nowMs : Date.now()
  var next = []
  for (var i = 0; i < (snapshot || []).length; i++) next = upsertDevice(next, snapshot[i], seen)
  return next
}

// Frontend mirror of the helper PEER_TTL: `device` events are additive and
// the helper only re-emits an authoritative `peer_snapshot` every 5s while
// discovery runs, so a peer that leaves between snapshots would otherwise
// stick on the card. Rows without a numeric lastSeen are stale: they can
// never age out, so they are pruned instead of kept immortal.
function pruneStaleDevices(devices, nowMs, ttlMs) {
  var list = devices || []
  var now = (typeof nowMs === "number" && isFinite(nowMs)) ? nowMs : Date.now()
  var ttl = Number(ttlMs)
  if (!(ttl > 0)) return list.slice()
  return list.filter(function(row) {
    if (!row || typeof row.lastSeen !== "number" || !isFinite(row.lastSeen)) return false
    return (now - row.lastSeen) <= ttl
  })
}

function incomingSummary(files) {
  if (!files || files.length === 0) return "Transfer"
  if (files.length === 1) return String(files[0].name || "Transfer")
  return String(files[0].name || "Transfer") + " + " + (files.length - 1) + " more"
}

function enqueueIncoming(queue, request) {
  var next = (queue || []).slice()
  if (!request || !request.requestId) return next
  for (var i = 0; i < next.length; i++) {
    if (next[i] && next[i].requestId === request.requestId) {
      next[i] = request
      return next
    }
  }
  next.push(request)
  return next
}

function removeIncoming(queue, requestId) {
  return (queue || []).filter(function(request) {
    return request && request.requestId !== requestId
  })
}

function currentIncoming(queue) {
  return queue && queue.length ? queue[0] : null
}

// Text-only send shaping (v1.0 subset: no PIN). Returns null
// when there is nothing valid to send so callers refuse visibly instead of
// transmitting an empty payload.
function sendTextCommand(device, text, transferId) {
  if (!device || !device.fingerprint || !device.alias) return null
  var body = String(text || "")
  if (body === "") return null
  if (!transferId || String(transferId) === "") return null
  return { command: "send_text", transfer_id: String(transferId), device: device, text: body }
}

// Multi-file send shaping (v1.1: PC -> phone, no PIN). Trims and filters
// empty entries, preserves picker order, returns null when zero usable paths
// remain so callers refuse instead of transmitting an empty file set.
// Wire shape matches the vendored helper SendFiles contract:
// {command:"send_files", transfer_id, device, paths[]}.
function sendFilesCommand(device, paths, transferId) {
  if (!device || !device.fingerprint || !device.alias) return null
  if (!transferId || String(transferId) === "") return null
  var usable = []
  for (var i = 0; i < ((paths || []).length); i++) {
    var entry = String(paths[i] || "")
    if (entry.trim() === "") continue
    usable.push(entry)
  }
  if (usable.length === 0) return null
  return { command: "send_files", transfer_id: String(transferId), device: device, paths: usable }
}

// Directory of a picked path, for remembering the file-picker start dir
// (v1.1 fix: zenity --filename). "/a/b/c.pdf" -> "/a/b", "/a/b/" -> "/a/b",
// "c.pdf" -> "". Never throws on odd input.
function dirOf(path) {
  var raw = String(path || "").trim()
  while (raw.length > 1 && raw.charAt(raw.length - 1) === "/") raw = raw.slice(0, -1)
  var slash = raw.lastIndexOf("/")
  if (slash < 0) return ""
  if (slash === 0) return "/"
  return raw.slice(0, slash)
}

// Nearby's release process only ever produces MAJOR.MINOR.PATCH with an
// optional prerelease suffix, so that is all this reads. Anything else is
// null, which callers treat as unknown rather than as equal: a version that
// cannot be read is not one the service can vouch for.
function parseVersion(value) {
  var match = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$/.exec(String(value || "").trim())
  if (!match) return null
  return {
    release: [Number(match[1]), Number(match[2]), Number(match[3])],
    prerelease: match[4] ? match[4].split(".") : []
  }
}

// SemVer precedence: numeric fields compare as numbers, a prerelease sorts
// before the release it leads up to, and prerelease identifiers compare as
// numbers when both are numeric and as text otherwise.
function compareVersions(left, right) {
  var a = parseVersion(left)
  var b = parseVersion(right)
  if (!a || !b) return null
  for (var i = 0; i < 3; i++) {
    if (a.release[i] !== b.release[i]) return a.release[i] < b.release[i] ? -1 : 1
  }
  if (a.prerelease.length === 0 || b.prerelease.length === 0) {
    if (a.prerelease.length === b.prerelease.length) return 0
    return a.prerelease.length === 0 ? 1 : -1
  }
  var longest = Math.max(a.prerelease.length, b.prerelease.length)
  for (var j = 0; j < longest; j++) {
    if (j >= a.prerelease.length) return -1
    if (j >= b.prerelease.length) return 1
    var x = a.prerelease[j]
    var y = b.prerelease[j]
    var xNumeric = /^\d+$/.test(x)
    var yNumeric = /^\d+$/.test(y)
    if (xNumeric && yNumeric) {
      if (Number(x) !== Number(y)) return Number(x) < Number(y) ? -1 : 1
      continue
    }
    if (xNumeric !== yNumeric) return xNumeric ? -1 : 1
    if (x !== y) return x < y ? -1 : 1
  }
  return 0
}

// A helper is good enough when it is at least the oldest one the service
// knows how to drive. An unreadable version on either side is a refusal.
function helperSatisfies(requiredVersion, helperVersion) {
  var order = compareVersions(helperVersion, requiredVersion)
  return order !== null && order >= 0
}

if (typeof module !== "undefined") module.exports = { parseLine, upsertDevice, snapshotDevices, pruneStaleDevices, incomingSummary, enqueueIncoming, removeIncoming, currentIncoming, sendTextCommand, sendFilesCommand, dirOf, parseVersion, compareVersions, helperSatisfies }
