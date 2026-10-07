import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// VPN bar widget: connect/disconnect existing OpenVPN NetworkManager
// profiles, and create/edit/import new ones. All NetworkManager access goes
// through the small bash/python helpers in bin/, invoked the same way the
// built-in network/bluetooth panels shell out to omarchy-network-* /
// omarchy-bluetooth-* -- this plugin owns no D-Bus/NM bindings directly.
Panel {
  id: root
  moduleName: "io.github.hcduller.vpn"
  ipcTarget: "io.github.hcduller.vpn"
  manageIpc: false

  // Derived from this file's own location rather than hardcoding
  // ~/.config/omarchy/plugins/<id> -- keeps bin/ resolvable no matter what
  // folder name the plugin is installed/cloned under, so renaming the
  // plugin id (or a user manually renaming the folder) can't silently break
  // every helper-script call the way a hardcoded HOME+id path would.
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string binDir: pluginDir + "/bin"

  readonly property int refreshIntervalSec: {
    var n = parseInt(String(setting("refreshIntervalSec", 5)), 10)
    if (!isFinite(n) || n < 2) return 5
    return Math.min(60, n)
  }

  // ---- connection list state ---------------------------------------------

  property var connections: []          // [{uuid,name,state,autoconnect}]
  // uuid -> { kind: "connecting"|"disconnecting"|"error", message: string }
  // Overrides the polled state until nmcli confirms the change (or the
  // panel gives up), same idea as Bluetooth's pendingActions map.
  property var pendingActions: ({})

  function cloneMap(map) {
    var next = {}
    for (var k in map) if (Object.prototype.hasOwnProperty.call(map, k)) next[k] = map[k]
    return next
  }

  function pendingFor(uuid) {
    return pendingActions[uuid] || null
  }

  function setPending(uuid, kind, message) {
    var next = cloneMap(pendingActions)
    if (kind === null) delete next[uuid]
    else next[uuid] = { kind: kind, message: message || "" }
    pendingActions = next
  }

  // Rows for the list: polled nmcli state with any in-flight action overlaid.
  readonly property var rows: {
    var list = []
    var conns = connections || []
    for (var i = 0; i < conns.length; i++) {
      var c = conns[i]
      var pending = pendingFor(c.uuid)
      var state = c.state
      var message = ""
      if (pending) {
        if (pending.kind === "connecting") state = "connecting"
        else if (pending.kind === "disconnecting") state = "idle"
        else if (pending.kind === "error") { state = "error"; message = pending.message }
      }
      list.push({ uuid: c.uuid, name: c.name, state: state, autoconnect: c.autoconnect, intentionalDisconnect: c.intentionalDisconnect, message: message })
    }
    return list
  }

  readonly property string aggregateState: Model.aggregateState(rows)
  readonly property color badgeIdleColor: root.bar ? Qt.darker(root.bar.foreground, 1.6) : Color.muted
  readonly property color badgeColor: Model.statusBadgeColor(aggregateState, badgeIdleColor)

  readonly property string heroStatusText: {
    for (var i = 0; i < rows.length; i++) if (rows[i].state === "connected") return "Connected — " + rows[i].name
    for (var j = 0; j < rows.length; j++) if (rows[j].state === "connecting") return "Connecting to " + rows[j].name + "…"
    for (var k = 0; k < rows.length; k++) if (rows[k].state === "error") return rows[k].message || "Connection failed"
    return rows.length === 0 ? "No VPN connections" : ""
  }

  // ---- panel mode: browsing the list vs. the create/edit form ------------

  property string mode: "list"   // "list" | "form"
  property string editingUuid: ""
  property var form: Model.emptyForm()
  property bool advancedOpen: false
  property bool formBusy: false
  property bool justSaved: false
  property string formError: ""
  property bool importBusy: false

  // Field the last "browse…" click should fill in once the file picker
  // returns (ca/cert/key/tlsAuthFile).
  property string browseTarget: ""

  function setFormField(key, value) {
    var next = {}
    for (var k in root.form) next[k] = root.form[k]
    next[key] = value
    root.form = next
  }

  function openCreate() {
    form = Model.emptyForm()
    editingUuid = ""
    advancedOpen = false
    formError = ""
    justSaved = false
    mode = "form"
  }

  function openEdit(uuid) {
    formError = ""
    justSaved = false
    editingUuid = uuid
    readProc.command = [root.binDir + "/omarchy-vpn-read", uuid]
    readProc.running = true
  }

  function cancelForm() {
    mode = "list"
    formError = ""
    justSaved = false
  }

  function saveForm() {
    var errors = Model.validateForm(root.form)
    if (errors.length > 0) {
      formError = errors.join(" · ")
      return
    }
    var data = Model.escapedDataMap(Model.buildVpnDataFields(root.form))
    var payload = {
      uuid: editingUuid,
      name: root.form.name,
      autoconnect: !!root.form.autoconnect,
      data: data,
      password: root.form.password || ""
    }
    formBusy = true
    formError = ""
    justSaved = false
    saveProc.command = [root.binDir + "/omarchy-vpn-save"]
    saveProc.jsonInput = JSON.stringify(payload)
    saveProc.running = true
  }

  function runImport() {
    importBusy = true
    formError = ""
    importProc.command = [root.binDir + "/omarchy-vpn-import"]
    importProc.running = true
  }

  function browseForField(field) {
    browseTarget = field
    pickProc.command = [root.binDir + "/omarchy-vpn-pick-file"]
    pickProc.running = true
  }

  function addExtraField() {
    var next = (root.form.extra || []).slice()
    next.push({ key: "", value: "" })
    setFormField("extra", next)
  }

  function removeExtraField(index) {
    var next = (root.form.extra || []).slice()
    next.splice(index, 1)
    setFormField("extra", next)
  }

  function setExtraField(index, key, value) {
    var next = (root.form.extra || []).slice()
    if (index < 0 || index >= next.length) return
    next[index] = { key: key, value: value }
    setFormField("extra", next)
  }

  function addRemoteField() {
    var next = (root.form.remotes || []).slice()
    next.push(Model.emptyRemote())
    setFormField("remotes", next)
  }

  function removeRemoteField(index) {
    var next = (root.form.remotes || []).slice()
    if (next.length <= 1) return
    next.splice(index, 1)
    setFormField("remotes", next)
  }

  function setRemoteField(index, key, value) {
    var next = (root.form.remotes || []).slice()
    if (index < 0 || index >= next.length) return
    var updated = {}
    for (var k in next[index]) updated[k] = next[index][k]
    updated[key] = value
    next[index] = updated
    setFormField("remotes", next)
  }

  // ---- connect / disconnect / delete --------------------------------------

  function connectionAt(uuid) {
    for (var i = 0; i < connections.length; i++) if (connections[i].uuid === uuid) return connections[i]
    return null
  }

  function toggleConnect(uuid) {
    var c = connectionAt(uuid)
    if (!c) return
    var pending = pendingFor(uuid)
    if (pending && (pending.kind === "connecting" || pending.kind === "disconnecting")) return
    if (c.state === "connected") disconnectRow(uuid)
    else connectRow(uuid)
  }

  // ---- connect-time authentication ----------------------------------------
  // The prompt is owned by the plugin (not nm-applet's secret agent): secrets
  // go to nmcli through a private passwd-file, so NetworkManager never asks an
  // agent. A wrong password therefore fails once, shows inline, and stays
  // entirely under the user's control -- no re-prompt loop.
  property string authUuid: ""
  property string authUser: ""
  property string authPass: ""
  property bool authSave: false
  property bool authBusy: false
  property string authError: ""

  function connectRow(uuid) {
    // Decide whether a password must be asked for before touching nmcli.
    authCheckProc.uuid = uuid
    authCheckProc.command = [root.binDir + "/omarchy-vpn-read", uuid]
    authCheckProc.running = true
  }

  // Store the password on an existing profile (secret + flags=1) without
  // rebuilding the rest of vpn.data.
  function saveAuthSecret(uuid, password) {
    savePassProc.command = [root.binDir + "/omarchy-vpn-store-secret", uuid]
    savePassProc.jsonInput = JSON.stringify({ password: password })
    savePassProc.running = true
  }

  function cancelAuth() {
    authUuid = ""
    authPass = ""
    authError = ""
    authBusy = false
  }

  function submitAuth() {
    if (authBusy || authUuid === "") return
    if (authUser.trim() === "" || authPass === "") {
      authError = "Username and password are required"
      return
    }
    authBusy = true
    authError = ""
    var c = connectionAt(authUuid)
    // Persist a changed username first (non-secret, plain modify), then connect.
    if (authUser !== authOriginalUser) {
      userProc.uuid = authUuid
      userProc.command = [root.binDir + "/omarchy-vpn-set-username", authUuid, authUser]
      userProc.running = true
    } else {
      runAuthConnect()
    }
  }

  property string authOriginalUser: ""

  function runAuthConnect() {
    connectProc.uuid = authUuid
    connectProc.fromPrompt = true
    connectProc.secretJson = JSON.stringify({ password: authPass })
    connectProc.command = [root.binDir + "/omarchy-vpn-connect", authUuid, "--stdin-secrets"]
    connectProc.running = true
  }

  function startConnect(uuid) {
    setPending(uuid, "connecting")
    connectProc.uuid = uuid
    connectProc.fromPrompt = false
    connectProc.secretJson = ""
    connectProc.command = [root.binDir + "/omarchy-vpn-connect", uuid]
    connectProc.running = true
  }

  function disconnectRow(uuid) {
    Quickshell.execDetached([root.binDir + "/omarchy-vpn-notify", "mark-disconnect", uuid])
    setPending(uuid, "disconnecting")
    disconnectProc.uuid = uuid
    disconnectProc.command = [root.binDir + "/omarchy-vpn-disconnect", uuid]
    disconnectProc.running = true
  }

  property string confirmDeleteUuid: ""
  property string confirmDeleteName: ""

  function requestDelete(uuid, name) {
    confirmDeleteUuid = uuid
    confirmDeleteName = name
  }

  function confirmDelete() {
    if (confirmDeleteUuid === "") return
    deleteProc.command = [root.binDir + "/omarchy-vpn-delete", confirmDeleteUuid]
    deleteProc.running = true
    confirmDeleteUuid = ""
  }

  function cancelDelete() {
    confirmDeleteUuid = ""
  }

  function refresh() {
    if (statusProc.running) return
    statusProc.command = [root.binDir + "/omarchy-vpn-status"]
    statusProc.running = true
  }

  function updateConnections(raw) {
    var previous = root.connections
    var parsed = Model.parseStatusList(raw)
    connections = parsed

    var next = cloneMap(pendingActions)
    var changed = false

    // Detect connections that dropped from "connected" to something else
    // without us having asked for it (no "disconnecting" overlay in flight)
    // -- a server-side timeout, a killed process, a network change, etc.
    // The badge needs to flag this as an error rather than silently going
    // back to idle, and the user needs an OS-level heads up since they may
    // not have the panel open to notice the bar badge at all.
    for (var p = 0; p < previous.length; p++) {
      var prevConn = previous[p]
      if (prevConn.state !== "connected") continue

      var pendingForPrev = next[prevConn.uuid]
      if (pendingForPrev && pendingForPrev.kind === "disconnecting") continue

      var current = connectionAt(prevConn.uuid)
      var stillConnected = current && current.state === "connected"
      if (stillConnected || prevConn.intentionalDisconnect) continue

      next[prevConn.uuid] = { kind: "error", message: "Connection was interrupted" }
      changed = true
      pendingErrorTimeout.restart()
      root.notifyUnexpectedDisconnect(prevConn.uuid, prevConn.name)
    }

    // Drop pending overlays once nmcli agrees with what we asked for.
    for (var uuid in next) {
      var c = connectionAt(uuid)
      var pending = next[uuid]
      if (pending.kind === "connecting" && c && c.state === "connected") { delete next[uuid]; changed = true }
      else if (pending.kind === "disconnecting" && c && c.state === "idle") { delete next[uuid]; changed = true }
      else if (!c && pending.kind !== "error") { delete next[uuid]; changed = true }
    }
    if (changed) pendingActions = next
  }

  // A real OS-level notification (not just the bar badge/panel) for a VPN
  // connection that dropped without the user asking for it -- e.g. the
  // server closed the tunnel, a network change killed it, the process died.
  // Uses network-vpn-symbolic rather than any nm-applet icon name: that one
  // is confirmed to actually resolve in the current icon theme, unlike
  // nm-applet's own "gnome-lockscreen" request for its equivalent toast.
  //
  // Routed through omarchy-vpn-notify (not notify-send directly) so that
  // running one instance of this plugin per monitor -- which Omarchy does
  // -- doesn't turn one real disconnect into one notification per monitor.
  function notifyUnexpectedDisconnect(uuid, name) {
    Quickshell.execDetached([
      root.binDir + "/omarchy-vpn-notify",
      "disconnect",
      uuid,
      "VPN Disconnected",
      "Connection to \"" + (name || "VPN") + "\" was interrupted."
    ])
  }

  function notifyConnectionEstablished(uuid) {
    var name = "VPN"
    var c = connectionAt(uuid)
    if (c && c.name) name = c.name
    Quickshell.execDetached([
      root.binDir + "/omarchy-vpn-notify",
      "connected",
      uuid,
      "VPN Connected",
      "Connection to \"" + name + "\" was successfully established."
    ])
  }

  onOpenedChanged: {
    if (opened) {
      mode = "list"
      refresh()
    }
  }

  Timer {
    // Always polling, not just while the panel is open: the bar badge (and
    // the unexpected-disconnect notification below) both need to reflect
    // reality even when nobody has the panel open to see it.
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: pendingErrorTimeout
    interval: 15000
    repeat: false
  }

  // ---- processes -----------------------------------------------------------

  Process {
    id: statusProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateConnections(text) }
  }

  Process {
    id: readProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var fields = {}
        var lines = text.split("\n")
        for (var i = 0; i < lines.length; i++) {
          var idx = lines[i].indexOf("\t")
          if (idx === -1) continue
          fields[lines[i].substring(0, idx)] = lines[i].substring(idx + 1)
        }
        var data = Model.parseVpnData(fields.data || "")
        root.form = Model.formFromVpnData(fields.name || "", data, (fields.autoconnect || "") === "yes", (fields.secrets || "") === "stored")
        root.advancedOpen = false
        root.mode = "form"
      }
    }
  }

  Process {
    id: saveProc
    property string jsonInput: ""
    stdinEnabled: true
    stdout: StdioCollector { id: saveStdout; waitForEnd: true }
    stderr: StdioCollector { id: saveStderr; waitForEnd: true }
    onStarted: { write(jsonInput + "\n"); jsonInput = "" }
    onExited: function(exitCode) {
      root.formBusy = false
      if (exitCode === 0) {
        var uuid = (saveStdout.text || "").trim()
        if (uuid !== "") root.editingUuid = uuid
        if (root.form.password) {
          // The secret is stored now; keep the form consistent so a later
          // save with a blank password doesn't downgrade the flags.
          root.setFormField("passwordFlags", "1")
          root.setFormField("password", "")
        }
        root.justSaved = true
        savedFlashTimer.restart()
        root.refresh()
      } else {
        root.formError = (saveStderr.text || "Failed to save connection").trim()
      }
    }
  }

  Timer {
    id: savedFlashTimer
    interval: 1500
    repeat: false
    onTriggered: root.justSaved = false
  }

  Process {
    id: importProc
    stdout: StdioCollector { id: importStdout; waitForEnd: true }
    stderr: StdioCollector { id: importStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.importBusy = false
      if (exitCode !== 0) {
        var err = (importStderr.text || "").trim()
        if (err !== "") root.formError = err
        return
      }
      var line = (importStdout.text || "").split("\n")[0] || ""
      var idx = line.indexOf("\t")
      var uuid = idx === -1 ? line.trim() : line.substring(0, idx)
      if (uuid !== "") root.openEdit(uuid)
    }
  }

  Process {
    id: pickProc
    stdout: StdioCollector { id: pickStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0 && root.browseTarget !== "") {
        var path = (pickStdout.text || "").trim()
        if (path !== "") root.setFormField(root.browseTarget, path)
      }
      root.browseTarget = ""
    }
  }

  Process {
    id: authCheckProc
    property string uuid: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var fields = {}
        var lines = text.split("\n")
        for (var i = 0; i < lines.length; i++) {
          var idx = lines[i].indexOf("\t")
          if (idx === -1) continue
          fields[lines[i].substring(0, idx)] = lines[i].substring(idx + 1)
        }
        var data = Model.parseVpnData(fields.data || "")
        var needsPassword = (data["connection-type"] || "password-tls") !== "tls"
        var stored = (fields.secrets || "") === "stored"
        var uuid = authCheckProc.uuid
        if (needsPassword && !stored) {
          var c = root.connectionAt(uuid)
          root.authUuid = uuid
          root.authUser = data.username || ""
          root.authOriginalUser = data.username || ""
          root.authPass = ""
          root.authSave = !!(c && c.autoconnect)
          root.authError = ""
          root.authBusy = false
        } else {
          root.startConnect(uuid)
        }
      }
    }
  }

  Process {
    id: userProc
    property string uuid: ""
    stderr: StdioCollector { id: userStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.authOriginalUser = root.authUser
        root.runAuthConnect()
      } else {
        root.authBusy = false
        root.authError = (userStderr.text || "Could not update username").trim()
      }
    }
  }

  Process {
    id: savePassProc
    property string jsonInput: ""
    stdinEnabled: true
    onStarted: { write(jsonInput + "\n"); jsonInput = "" }
    onExited: root.refresh()
  }

  Process {
    id: connectProc
    property string uuid: ""
    property bool fromPrompt: false
    property string secretJson: ""
    stdinEnabled: true
    stderr: StdioCollector { id: connectStderr; waitForEnd: true }
    onStarted: {
      if (secretJson !== "") { write(secretJson + "\n"); secretJson = "" }
    }
    onExited: function(exitCode) {
      if (fromPrompt) {
        root.authBusy = false
        if (exitCode === 0) {
          // Optionally keep the secret so future connects (and autoconnect)
          // don't need to ask again.
          if (root.authSave) root.saveAuthSecret(connectProc.uuid, root.authPass)
          root.setPending(connectProc.uuid, null)
          root.cancelAuth()
          root.notifyConnectionEstablished(connectProc.uuid)
        } else {
          // Bounded retry: surface the error, keep the prompt open, wait for
          // the user. Nothing here ever re-submits on its own.
          root.authError = ((connectStderr.text || "Connection failed").trim().split("\n")[0])
          root.setPending(connectProc.uuid, null)
        }
        root.refresh()
        return
      }
      if (exitCode === 0) {
        root.setPending(connectProc.uuid, null)
        root.notifyConnectionEstablished(connectProc.uuid)
      } else {
        var msg = (connectStderr.text || "Connection failed").trim()
        root.setPending(connectProc.uuid, "error", msg)
        pendingErrorTimeout.restart()
      }
      root.refresh()
    }
  }

  Process {
    id: disconnectProc
    property string uuid: ""
    onExited: function(exitCode) {
      root.setPending(disconnectProc.uuid, null)
      root.refresh()
    }
  }

  Process {
    id: deleteProc
    onExited: function() { root.refresh() }
  }

  Connections {
    target: pendingErrorTimeout
    function onTriggered() {
      // Clear any stale error overlays so a row doesn't stay red forever.
      var next = root.cloneMap(root.pendingActions)
      var changed = false
      for (var uuid in next) {
        if (next[uuid].kind === "error") { delete next[uuid]; changed = true }
      }
      if (changed) root.pendingActions = next
    }
  }

  // ---- bar icon --------------------------------------------------------

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: "VPN"
    iconComponent: badgeIconComponent
    onPressed: function() { root.toggle() }
  }

  Component {
    id: badgeIconComponent
    Item {
      Text {
        anchors.centerIn: parent
        text: "󰒃"
        color: root.bar ? root.bar.barForeground : Color.foreground
        font.pixelSize: Style.bar.iconFont
      }
      Rectangle {
        width: Style.space(6)
        height: Style.space(6)
        radius: width / 2
        color: root.badgeColor
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: -Style.space(1)
        anchors.bottomMargin: -Style.space(1)
        border.width: 1
        border.color: root.bar ? root.bar.background : Color.background
      }
    }
  }

  IpcHandler {
    target: "io.github.hcduller.vpn"
    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
  }

  // ---- panel -------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(Math.min(column.implicitHeight, Style.space(520)))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.mode === "form" || root.confirmDeleteUuid !== "" || root.authUuid !== ""
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // PanelKeyCatcher's own Escape handling is skipped while `blocked` is
      // true (needed so typing in the form's text fields isn't swallowed by
      // its j/k/arrow-key navigation), so Escape needs its own path here:
      // cancel the delete confirmation if it's open, otherwise back out of
      // the form to the list, without closing the whole panel.
      Shortcut {
        sequence: "Escape"
        enabled: root.mode === "form" || root.confirmDeleteUuid !== "" || root.authUuid !== ""
        onActivated: {
          if (root.authUuid !== "") root.cancelAuth()
          else if (root.confirmDeleteUuid !== "") root.cancelDelete()
          else root.cancelForm()
        }
      }

      Flickable {
        id: scrollArea
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        // Reserve room on both edges so the scrollbar never overlaps text
        // or buttons -- it floats in its own right-hand gutter instead of
        // sitting on top of full-width rows.
        readonly property real sidePadding: Style.space(10)

        Column {
          id: column
          x: scrollArea.sidePadding
          width: scrollArea.width - scrollArea.sidePadding * 2
          spacing: Style.space(14)

          // ---------- Hero ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "󰒃"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "VPN"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Text {
                visible: root.heroStatusText !== ""
                height: visible ? implicitHeight : 0
                text: root.heroStatusText.toUpperCase()
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          PanelSeparator {
            visible: root.mode === "list"
            foreground: root.bar.foreground
          }

          // ---------- List mode ----------
          Column {
            width: parent.width
            visible: root.mode === "list"
            spacing: Style.space(10)

            Button {
              width: parent.width
              leftAlign: true
              bordered: true
              iconText: "󰐕"
              text: "New Connection"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: root.openCreate()
            }

            Text {
              visible: root.rows.length === 0
              width: parent.width
              text: "No OpenVPN connections yet. Create one or import a .ovpn file."
              wrapMode: Text.WordWrap
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: root.rows
              delegate: Column {
                required property var modelData
                width: parent.width
                spacing: Style.space(6)

                ConnectionRow {
                  width: parent.width
                  row: modelData
                }

                AuthPrompt {
                  width: parent.width
                  visible: root.authUuid === modelData.uuid
                }
              }
            }
          }

          // ---------- Form mode (create/edit/import) ----------
          Column {
            width: parent.width
            visible: root.mode === "form"
            spacing: Style.space(12)

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                text: root.editingUuid === "" ? "New Connection" : "Edit Connection"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.title
              }
            }

            Button {
              width: parent.width
              leftAlign: true
              bordered: true
              iconText: "󰈔"
              text: root.importBusy ? "Waiting for file…" : "Import .ovpn File…"
              enabled: !root.importBusy
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: root.runImport()
            }

            PanelSeparator { foreground: root.bar.foreground }

            FormField {
              label: "Name"
              TextField {
                width: parent.width
                text: root.form.name
                placeholderText: "My VPN"
                onTextEdited: root.setFormField("name", text)
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(8)

              PanelSectionHeader {
                text: root.form.remotes.length > 1 ? "SERVER ADDRESSES" : "SERVER ADDRESS"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              // OpenVPN allows multiple `remote` directives -- the client
              // tries each in turn. One row per address, with add/remove
              // controls, matching how "Custom fields" below are edited.
              Repeater {
                model: root.form.remotes
                delegate: Row {
                  required property var modelData
                  required property int index
                  width: parent.width
                  spacing: Style.space(8)

                  FormField {
                    label: "Address"
                    width: parent.width - portField.width - protoField.width - removeBtn.width - Style.space(24)
                    TextField {
                      width: parent.width
                      text: modelData.host
                      placeholderText: "vpn.example.com"
                      onTextEdited: root.setRemoteField(index, "host", text)
                    }
                  }
                  FormField {
                    id: portField
                    label: "Port"
                    width: Style.space(64)
                    TextField {
                      width: parent.width
                      text: modelData.port
                      placeholderText: "1194"
                      onTextEdited: root.setRemoteField(index, "port", text)
                    }
                  }
                  FormField {
                    id: protoField
                    label: "Protocol"
                    width: Style.space(84)
                    Dropdown {
                      width: parent.width
                      showLabel: false
                      value: modelData.proto
                      options: Model.protoOptions
                      onChanged: function(v) { root.setRemoteField(index, "proto", v) }
                    }
                  }
                  PanelActionButton {
                    id: removeBtn
                    anchors.bottom: parent.bottom
                    visible: root.form.remotes.length > 1
                    iconText: "󰅙"
                    tooltipText: "Remove address"
                    foreground: root.bar.foreground
                    hoverColor: Color.urgent
                    fontFamily: root.bar.fontFamily
                    onClicked: root.removeRemoteField(index)
                  }
                }
              }

              Button {
                width: parent.width
                leftAlign: true
                bordered: true
                iconText: "󰐕"
                text: "Add server address"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onClicked: root.addRemoteField()
              }
            }

            FormField {
              label: "Authentication"
              Dropdown {
                width: parent.width
                showLabel: false
                value: root.form.authMode
                options: Model.authModeOptions
                onChanged: function(v) { root.setFormField("authMode", v) }
              }
            }

            FileField {
              visible: root.form.authMode !== "password"
              label: "CA Certificate"
              path: root.form.ca
              onPathEdited: function(v) { root.setFormField("ca", v) }
              onBrowse: root.browseForField("ca")
            }

            FileField {
              visible: root.form.authMode !== "password"
              label: "Client Certificate"
              path: root.form.cert
              onPathEdited: function(v) { root.setFormField("cert", v) }
              onBrowse: root.browseForField("cert")
            }

            FileField {
              visible: root.form.authMode !== "password"
              label: "Client Key"
              path: root.form.key
              onPathEdited: function(v) { root.setFormField("key", v) }
              onBrowse: root.browseForField("key")
            }

            FormField {
              visible: root.form.authMode !== "tls"
              label: "Username"
              TextField {
                width: parent.width
                text: root.form.username
                onTextEdited: root.setFormField("username", text)
              }
            }

            FormField {
              visible: root.form.authMode !== "tls"
              label: root.editingUuid === "" ? "Password" : "Password (leave blank to keep current)"
              TextField {
                width: parent.width
                password: true
                text: root.form.password
                onTextEdited: root.setFormField("password", text)
              }
            }

            Toggle {
              label: "Connect automatically"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              checked: root.form.autoconnect
              onClicked: root.setFormField("autoconnect", !root.form.autoconnect)
            }

            Button {
              width: parent.width
              leftAlign: true
              iconText: root.advancedOpen ? "󰅀" : "󰅂"
              text: "Advanced"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: root.advancedOpen = !root.advancedOpen
            }

            Column {
              width: parent.width
              visible: root.advancedOpen
              spacing: Style.space(12)

              Row {
                width: parent.width
                spacing: Style.space(8)

                FormField {
                  label: "Cipher"
                  width: (parent.width - Style.space(8)) / 2
                  Dropdown {
                    width: parent.width
                    showLabel: false
                    value: root.form.cipher
                    options: Model.cipherOptions
                    onChanged: function(v) { root.setFormField("cipher", v) }
                  }
                }
                FormField {
                  label: "Auth Digest"
                  width: (parent.width - Style.space(8)) / 2
                  Dropdown {
                    width: parent.width
                    showLabel: false
                    value: root.form.authDigest === "" ? "none" : root.form.authDigest
                    options: Model.authDigestOptions
                    onChanged: function(v) { root.setFormField("authDigest", v === "none" ? "" : v) }
                  }
                }
              }

              FormField {
                label: "Device Type"
                Dropdown {
                  width: parent.width
                  showLabel: false
                  value: root.form.devType
                  options: Model.devTypeOptions
                  onChanged: function(v) { root.setFormField("devType", v) }
                }
              }

              FileField {
                label: "TLS Auth/Crypt Key"
                path: root.form.tlsAuthFile
                onPathEdited: function(v) { root.setFormField("tlsAuthFile", v) }
                onBrowse: root.browseForField("tlsAuthFile")
              }

              FormField {
                visible: root.form.tlsAuthFile !== ""
                label: "TLS Auth Direction"
                Dropdown {
                  width: parent.width
                  showLabel: false
                  value: root.form.tlsAuthDir
                  options: [{ value: "1", label: "1 (client)" }, { value: "0", label: "0" }, { value: "", label: "None (tls-crypt)" }]
                  onChanged: function(v) { root.setFormField("tlsAuthDir", v) }
                }
              }

              Toggle {
                label: "Enable compression (comp-lzo)"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                checked: root.form.compression
                onClicked: root.setFormField("compression", !root.form.compression)
              }

              PanelSectionHeader {
                text: "CUSTOM FIELDS"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              Repeater {
                model: root.form.extra
                delegate: Row {
                  required property var modelData
                  required property int index
                  width: parent.width
                  spacing: Style.space(6)

                  TextField {
                    width: (parent.width - removeBtn.width - Style.space(12)) * 0.4
                    text: modelData.key
                    placeholderText: "key"
                    onTextEdited: root.setExtraField(index, text, modelData.value)
                  }
                  TextField {
                    width: (parent.width - removeBtn.width - Style.space(12)) * 0.6
                    text: modelData.value
                    placeholderText: "value"
                    onTextEdited: root.setExtraField(index, modelData.key, text)
                  }
                  PanelActionButton {
                    id: removeBtn
                    iconText: "󰅙"
                    tooltipText: "Remove field"
                    foreground: root.bar.foreground
                    hoverColor: Color.urgent
                    fontFamily: root.bar.fontFamily
                    onClicked: root.removeExtraField(index)
                  }
                }
              }

              Button {
                width: parent.width
                leftAlign: true
                bordered: true
                iconText: "󰐕"
                text: "Add custom field"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onClicked: root.addExtraField()
              }
            }

            Text {
              visible: root.formError !== ""
              width: parent.width
              text: root.formError
              wrapMode: Text.WordWrap
              color: Color.urgent
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Row {
              width: parent.width
              spacing: Style.space(8)
              layoutDirection: Qt.RightToLeft

              Button {
                bordered: true
                text: root.formBusy ? "Saving…" : (root.justSaved ? "Saved" : "Save")
                enabled: !root.formBusy
                foreground: root.bar.foreground
                accent: Color.accent
                fontFamily: root.bar.fontFamily
                onClicked: root.saveForm()
              }
              Button {
                bordered: true
                text: "Cancel"
                enabled: !root.formBusy
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onClicked: root.cancelForm()
              }
            }
          }
        }
      }

      ConfirmDialog {
        id: deleteConfirm
        anchors.fill: parent
        opened: root.confirmDeleteUuid !== ""
        message: "Delete VPN connection “" + root.confirmDeleteName + "”?"
        cancelText: "Cancel"
        confirmText: "Delete"
        onCanceled: root.cancelDelete()
        onConfirmed: root.confirmDelete()
      }
    }
  }

  // A labeled text-input row: small-caps label above the field, matching the
  // rest of the panel kit's form conventions (PanelSectionHeader look, but
  // scoped to a single field rather than a whole section).
  component FormField: Column {
    id: field
    property string label: ""
    default property alias content: holder.children

    width: parent.width
    spacing: Style.space(4)

    Text {
      text: field.label
      color: Qt.darker(root.bar.foreground, 1.4)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Item {
      id: holder
      width: parent.width
      implicitHeight: childrenRect.height
    }
  }

  // A path field with a "browse…" button that opens the native file picker.
  component FileField: FormField {
    id: fileField
    property string path: ""
    property bool visible_: true
    signal pathEdited(string value)
    signal browse()

    Row {
      width: parent.width
      spacing: Style.space(6)

      TextField {
        width: parent.width - browseBtn.width - Style.space(10)
        text: fileField.path
        placeholderText: "/path/to/file.pem"
        onTextEdited: fileField.pathEdited(text)
      }
      PanelActionButton {
        id: browseBtn
        iconText: "󰉋"
        tooltipText: "Browse…"
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        onClicked: fileField.browse()
      }
    }
  }

  // One VPN connection row: provider-name square + name/status + connect
  // and edit icon buttons. Modeled on Bluetooth's DeviceRow.
  // Inline credentials prompt shown under a row whose profile has no stored
  // password. Username is editable (prefilled from the profile).
  component AuthPrompt: Column {
    id: prompt
    spacing: Style.space(8)
    height: visible ? implicitHeight : 0

    onVisibleChanged: if (visible) Qt.callLater(function() { passField.forceActiveFocus() })

    Item { width: 1; height: Style.space(2) }

    FormField {
      label: "Username"
      TextField {
        width: parent.width
        text: root.authUser
        enabled: !root.authBusy
        onTextEdited: root.authUser = text
        onAccepted: passField.forceActiveFocus()
      }
    }

    FormField {
      label: "Password"
      TextField {
        id: passField
        width: parent.width
        password: true
        text: root.authPass
        enabled: !root.authBusy
        onTextEdited: root.authPass = text
        onAccepted: root.submitAuth()
      }
    }

    Toggle {
      width: parent.width
      label: "Save password"
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
      checked: root.authSave
      onClicked: root.authSave = !root.authSave
    }

    Text {
      visible: root.authError !== ""
      width: parent.width
      text: root.authError
      wrapMode: Text.WordWrap
      color: Color.urgent
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Row {
      width: parent.width
      spacing: Style.space(8)
      layoutDirection: Qt.RightToLeft

      Button {
        bordered: true
        text: root.authBusy ? "Connecting…" : "Connect"
        enabled: !root.authBusy
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        onClicked: root.submitAuth()
      }
      Button {
        bordered: true
        text: "Cancel"
        enabled: !root.authBusy
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        onClicked: root.cancelAuth()
      }
    }

    PanelSeparator { foreground: root.bar.foreground }
  }

  component ConnectionRow: CursorSurface {
    id: connRow
    required property var row

    readonly property bool isConnected: row.state === "connected"
    readonly property bool isConnecting: row.state === "connecting"
    readonly property bool isError: row.state === "error"
    readonly property color rowStateColor: Model.statusBadgeColor(row.state, root.bar ? Qt.darker(root.bar.foreground, 1.6) : Color.muted)

    current: isConnected
    foreground: root.bar.foreground
    fill: Style.hoverFillFor(root.bar.foreground, Color.accent)
    currentFill: Style.selectedFillFor(root.bar.foreground, Color.accent)

    implicitHeight: content.implicitHeight + Style.space(12)

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggleConnect(connRow.row.uuid)
    }

    Item {
      id: content
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      implicitHeight: Math.max(square.implicitHeight, info.implicitHeight, actions.implicitHeight)

      // Provider-name square, same trick Network's DNS pills use: a bordered
      // Button sized as a fixed square with the connection's short name.
      Button {
        id: square
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(34)
        height: Style.space(34)
        bordered: true
        text: (connRow.row.name || "?").substring(0, 2).toUpperCase()
        fontSize: Style.font.bodySmall
        foreground: connRow.rowStateColor
        accent: connRow.rowStateColor

        Rectangle {
          visible: connRow.isConnecting
          anchors.fill: parent
          radius: parent.radius
          color: "transparent"
          border.width: 1
          border.color: connRow.rowStateColor
          opacity: 0.6

          SequentialAnimation on opacity {
            loops: Animation.Infinite
            running: connRow.isConnecting
            NumberAnimation { to: 0.15; duration: 600 }
            NumberAnimation { to: 0.6; duration: 600 }
          }
        }
      }

      Column {
        id: info
        anchors.left: square.right
        anchors.leftMargin: Style.space(10)
        anchors.right: actions.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter

        Text {
          text: connRow.row.name || "Connection"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          width: parent.width
        }
        Text {
          readonly property string statusText: connRow.isConnecting ? "Connecting…"
              : connRow.isConnected ? "Connected"
              : connRow.isError ? (connRow.row.message || "Connection failed")
              : ""
          visible: statusText !== ""
          height: visible ? implicitHeight : 0
          text: statusText
          color: connRow.rowStateColor
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
        }
      }

      Row {
        id: actions
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)

        PanelActionButton {
          iconText: connRow.isConnected ? "󰖪" : "󰐊"
          tooltipText: connRow.isConnected ? "Disconnect" : "Connect"
          foreground: root.bar.foreground
          hoverColor: root.bar.foreground
          fontFamily: root.bar.fontFamily
          onClicked: root.toggleConnect(connRow.row.uuid)
        }
        PanelActionButton {
          iconText: "󰏫"
          tooltipText: "Edit"
          foreground: root.bar.foreground
          hoverColor: root.bar.foreground
          fontFamily: root.bar.fontFamily
          onClicked: root.openEdit(connRow.row.uuid)
        }
        PanelActionButton {
          iconText: "󰩹"
          tooltipText: "Delete"
          foreground: root.bar.foreground
          hoverColor: Color.urgent
          fontFamily: root.bar.fontFamily
          onClicked: root.requestDelete(connRow.row.uuid, connRow.row.name)
        }
      }
    }
  }
}
