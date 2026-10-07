// Pure helpers for the VPN plugin: nmcli output parsing, vpn.data map
// building/escaping, and small option tables for the create/edit form.
// No Quickshell/QML imports here so this stays unit-testable like the
// network plugin's Model.js.

// ---- status list (from bin/omarchy-vpn-status) -----------------------

function parseStatusList(raw) {
  var lines = String(raw || "").split("\n")
  var rows = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (!line) continue
    var parts = line.split("\t")
    if (parts.length < 3) continue
    rows.push({
      uuid: parts[0] || "",
      name: parts[1] || "",
      state: parts[2] || "idle",
      autoconnect: (parts[3] || "") === "yes",
      intentionalDisconnect: (parts[4] || "") === "yes"
    })
  }
  return rows
}

// ---- nmcli vpn.data map parsing/building ------------------------------

// nmcli escapes ":" and "," inside map values with a backslash. Splitting
// naively on ", " breaks on fields like `remote` that legitimately contain
// escaped commas (multiple remote hosts). Instead we find every `key = `
// boundary and take everything between two boundaries as that key's raw
// value, which sidesteps the ambiguity entirely.
function parseVpnData(raw) {
  var result = {}
  var text = String(raw || "")
  if (text === "") return result

  var re = /([A-Za-z0-9_-]+) = /g
  var matches = []
  var m
  while ((m = re.exec(text)) !== null) {
    matches.push({ key: m[1], start: m.index, valueStart: m.index + m[0].length })
  }

  for (var i = 0; i < matches.length; i++) {
    var start = matches[i].valueStart
    var end = i + 1 < matches.length ? matches[i + 1].start : text.length
    var value = text.substring(start, end).replace(/,\s*$/, "")
    result[matches[i].key] = unescapeNmcliValue(value)
  }

  return result
}

// For READING nmcli's terse (`-g`/`-t`) output only. `:` is escaped there
// because it is nmcli's own terse-format field separator, not because the
// vpn.data map syntax cares about it.
function unescapeNmcliValue(value) {
  return String(value || "")
    .replace(/\\:/g, ":")
    .replace(/\\,/g, ",")
    .replace(/\\\\/g, "\\")
}

// For WRITING a value into a `vpn.data`/`vpn.secrets` map argument passed to
// `nmcli connection add/modify`. Only `,` is special there (it separates map
// entries), so colons (host:port:proto, absolute paths) are left alone --
// escaping them here would double-escape on the next read and corrupt the
// value (verified against a live NetworkManager instance while building this
// plugin). A literal backslash is escaped first so it can't be misread as
// an escape prefix for a following comma.
function escapeNmcliValue(value) {
  return String(value || "")
    .replace(/\\/g, "\\\\")
    .replace(/,/g, "\\,")
}

// ---- form <-> vpn.data field mapping ----------------------------------

var authModeOptions = [
  { value: "tls", label: "Certificates only" },
  { value: "password", label: "Username & password" },
  { value: "password-tls", label: "Certificates + username & password" }
]

var protoOptions = [
  { value: "udp", label: "UDP" },
  { value: "tcp", label: "TCP" }
]

var devTypeOptions = [
  { value: "tun", label: "TUN (routed)" },
  { value: "tap", label: "TAP (bridged)" }
]

var cipherOptions = [
  "AES-256-GCM", "AES-128-GCM", "CHACHA20-POLY1305",
  "AES-256-CBC", "AES-128-CBC", "BF-CBC"
]

var authDigestOptions = ["SHA1", "SHA256", "SHA512", "MD5", "none"]

function emptyForm() {
  return {
    name: "",
    remotes: [emptyRemote()],
    devType: "tun",
    authMode: "password-tls",
    ca: "",
    cert: "",
    key: "",
    username: "",
    password: "",
    cipher: "",
    authDigest: "",
    tlsAuthFile: "",
    tlsAuthDir: "1",
    compression: false,
    autoconnect: false,
    extra: []
  }
}

function emptyRemote() {
  return { host: "", port: "1194", proto: "udp" }
}

function buildRemoteValue(host, port, proto) {
  var h = String(host || "").trim()
  if (h === "") return ""
  var p = String(port || "1194").trim() || "1194"
  var pr = proto || "udp"
  return h + ":" + p + ":" + pr
}

// A config can legitimately list several `remote` directives (OpenVPN tries
// each in turn). NetworkManager's OpenVPN plugin folds all of them into a
// single `remote` vpn.data value, joined by a literal "<host:port:proto>, "
// separator -- which collides with vpn.data's own map-entry comma, so NM
// escapes that internal comma with a backslash to keep it out of nmcli's
// map parser. Building the whole vpn.data string through escapeNmcliValue
// (which escapes every comma generically) reproduces that exact convention
// with no special-casing needed. Splitting it back apart on the way in only
// needs to look for that same "\, " marker.
function buildRemotesValue(remotes) {
  var list = Array.isArray(remotes) ? remotes : []
  var values = []
  for (var i = 0; i < list.length; i++) {
    var v = buildRemoteValue(list[i].host, list[i].port, list[i].proto)
    if (v !== "") values.push(v)
  }
  return values.join(", ")
}

// Parses a `remote` value already run through unescapeNmcliValue (see
// parseVpnData) back into individual {host, port, proto} entries.
function parseRemotes(rawRemote) {
  var text = String(rawRemote || "")
  if (text === "") return []

  var parts = text.split(/\\,\s*/)
  var remotes = []
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i].trim()
    if (part === "") continue
    var segments = part.split(":")
    var remote = emptyRemote()
    if (segments.length >= 3) {
      remote.proto = segments[segments.length - 1]
      remote.port = segments[segments.length - 2]
      remote.host = segments.slice(0, segments.length - 2).join(":")
    } else if (segments.length === 2) {
      remote.host = segments[0]
      remote.port = segments[1]
    } else {
      remote.host = part
    }
    remotes.push(remote)
  }
  return remotes
}

// Known keys the form owns explicitly -- everything else read back from an
// existing profile lands in `extra` so editing never silently drops fields
// the form doesn't have a dedicated control for.
var knownDataKeys = {
  "remote": true, "dev": true, "connection-type": true, "remote-cert-tls": true,
  "ca": true, "cert": true, "key": true, "username": true, "password-flags": true,
  "data-ciphers": true, "auth": true, "ta": true, "ta-dir": true, "comp-lzo": true
}

// Builds the plain (unescaped) key/value map that will become vpn.data.
// Caller is responsible for escaping each value before handing it to nmcli
// (see escapeNmcliValue / escapedDataMap).
function buildVpnDataFields(form) {
  var f = form || {}
  var data = {}

  var remote = buildRemotesValue(f.remotes)
  if (remote !== "") data["remote"] = remote

  data["dev"] = f.devType || "tun"
  data["connection-type"] = f.authMode || "password-tls"
  data["remote-cert-tls"] = "server"

  var usesCert = f.authMode !== "password"
  var usesPassword = f.authMode !== "tls"

  if (usesCert && f.ca) data["ca"] = f.ca
  if (usesCert && f.cert) data["cert"] = f.cert
  if (usesCert && f.key) data["key"] = f.key
  if (usesPassword && f.username) data["username"] = f.username
  // Flags must match reality: "1" (stored in profile) with no stored secret
  // sends NetworkManager to a desktop secret agent on connect -- the source of
  // an endless wrong-password prompt loop. So "1" only when a password is being
  // saved now (or already is); otherwise "2" (ask at connect, which this
  // plugin does itself through its own prompt).
  if (!usesPassword) data["password-flags"] = "0"
  else if (f.password) data["password-flags"] = "1"
  else if (f.passwordFlags !== undefined && f.passwordFlags !== "") data["password-flags"] = String(f.passwordFlags)
  else data["password-flags"] = "2"

  if (f.cipher) data["data-ciphers"] = f.cipher
  if (f.authDigest && f.authDigest !== "none") data["auth"] = f.authDigest
  if (f.tlsAuthFile) {
    data["ta"] = f.tlsAuthFile
    data["ta-dir"] = f.tlsAuthDir !== undefined && f.tlsAuthDir !== "" ? String(f.tlsAuthDir) : "1"
  }
  if (f.compression) data["comp-lzo"] = "yes"

  if (Array.isArray(f.extra)) {
    for (var i = 0; i < f.extra.length; i++) {
      var row = f.extra[i]
      if (row && row.key) data[row.key] = row.value || ""
    }
  }

  return data
}

function escapedDataMap(data) {
  var out = {}
  for (var k in data) {
    if (Object.prototype.hasOwnProperty.call(data, k)) out[k] = escapeNmcliValue(data[k])
  }
  return out
}

// Reverse mapping: parsed vpn.data (already unescaped by parseVpnData) plus
// the connection name/autoconnect flag from omarchy-vpn-read -> form object
// for the edit dialog. Password is intentionally left blank -- nmcli never
// exposes vpn.secrets, so the user must re-enter it to change it.
function formFromVpnData(name, data, autoconnect, secretsStored) {
  var form = emptyForm()
  var d = data || {}
  form.name = name || ""
  form.autoconnect = !!autoconnect

  var remotes = parseRemotes(d.remote)
  form.remotes = remotes.length > 0 ? remotes : [emptyRemote()]

  form.devType = d.dev || "tun"
  form.authMode = d["connection-type"] || "password-tls"
  form.ca = d.ca || ""
  form.cert = d.cert || ""
  form.key = d.key || ""
  form.username = d.username || ""
  var flags = d["password-flags"]
  if (flags === "1" && secretsStored === false) flags = "2"
  form.passwordFlags = flags !== undefined ? flags : ""
  form.cipher = (d["data-ciphers"] || "").split(":")[0] || ""
  form.authDigest = d.auth || ""
  form.tlsAuthFile = d.ta || ""
  form.tlsAuthDir = d["ta-dir"] || "1"
  form.compression = d["comp-lzo"] === "yes"

  var extra = []
  for (var key in d) {
    if (!Object.prototype.hasOwnProperty.call(d, key)) continue
    if (knownDataKeys[key]) continue
    extra.push({ key: key, value: d[key] })
  }
  form.extra = extra

  return form
}

function validateForm(form) {
  var f = form || {}
  var errors = []
  if (!f.name || f.name.trim() === "") errors.push("Name is required")
  var remotes = Array.isArray(f.remotes) ? f.remotes : []
  var hasRemote = remotes.some(function(r) { return r && r.host && r.host.trim() !== "" })
  if (!hasRemote) errors.push("At least one server address is required")
  var usesCert = f.authMode !== "password"
  var usesPassword = f.authMode !== "tls"
  if (usesCert && (!f.ca || f.ca.trim() === "")) errors.push("CA certificate is required for this auth mode")
  if (usesPassword && (!f.username || f.username.trim() === "")) errors.push("Username is required for this auth mode")
  return errors
}

// ---- status -> badge color ---------------------------------------------
// The shell has no shared green/yellow color tokens (only foreground/
// background/accent/urgent/muted), so the VPN badge defines its own.
// Idle reuses the existing muted/gray token from qs.Commons.Color instead
// of inventing a second gray.
var badgeColors = {
  connecting: "#e5c07b",
  connected: "#4caf7d",
  error: "#c0392b"
}

function statusBadgeColor(state, muted) {
  if (state === "connecting") return badgeColors.connecting
  if (state === "connected") return badgeColors.connected
  if (state === "error") return badgeColors.error
  return muted
}

// Priority: error (something needs attention) > connecting > connected > idle.
// `rows` already carries "error" for any connection with a pending error
// overlay (failed connect, or an unexpected drop -- see Panel.qml's
// updateConnections), so scanning rows alone is sufficient; no separate
// out-of-band error flag is needed here.
function aggregateState(rows) {
  var list = Array.isArray(rows) ? rows : []
  for (var e = 0; e < list.length; e++) if (list[e].state === "error") return "error"
  for (var i = 0; i < list.length; i++) if (list[i].state === "connecting") return "connecting"
  for (var j = 0; j < list.length; j++) if (list[j].state === "connected") return "connected"
  return "idle"
}

if (typeof module !== "undefined") {
  module.exports = {
    parseStatusList: parseStatusList,
    parseVpnData: parseVpnData,
    unescapeNmcliValue: unescapeNmcliValue,
    escapeNmcliValue: escapeNmcliValue,
    authModeOptions: authModeOptions,
    protoOptions: protoOptions,
    devTypeOptions: devTypeOptions,
    cipherOptions: cipherOptions,
    authDigestOptions: authDigestOptions,
    emptyForm: emptyForm,
    emptyRemote: emptyRemote,
    buildRemoteValue: buildRemoteValue,
    buildRemotesValue: buildRemotesValue,
    parseRemotes: parseRemotes,
    buildVpnDataFields: buildVpnDataFields,
    escapedDataMap: escapedDataMap,
    formFromVpnData: formFromVpnData,
    validateForm: validateForm,
    badgeColors: badgeColors,
    statusBadgeColor: statusBadgeColor,
    aggregateState: aggregateState
  }
}
