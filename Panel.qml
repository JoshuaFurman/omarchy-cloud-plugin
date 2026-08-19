import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The Cloud panel: every connected service, what state it is in, and the one
// action each state actually wants.
//
// Rows are deliberately not uniform. A mounted service wants "open it"; one
// that needs signing in wants "sign in" and nothing else; a failed one wants
// to show why. Presenting all three with the same generic toggle would make
// the common case slower to use.
Panel {
  id: root
  moduleName: "furmware.cloud"
  ipcTarget: "furmware.cloud"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var cloud: null
  property bool openedFromHotkey: false

  // The bar tracks the widget in its slot, not this nested panel, so anything
  // the popout coordinator compares against has to be the widget.
  readonly property var barIdentity: hostWidget || root

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var remotes: cloud ? cloud.remotes : []
  readonly property bool rcloneInstalled: cloud ? cloud.rcloneInstalled : true
  readonly property int mountedCount: Model.mountedCount(remotes)

  // Focusable rows: one per remote, then the connect row. With rclone missing
  // there is exactly one thing to do, so the list collapses to it.
  readonly property int rowCount: rcloneInstalled ? remotes.length + 1 : 1
  readonly property int connectIndex: remotes.length

  property int cursorIndex: 0
  property bool cursorActive: false

  readonly property string heroMeta: {
    if (!rcloneInstalled) return "rclone not installed"
    if (remotes.length === 0) return "No services connected"
    if (mountedCount === remotes.length) return remotes.length === 1
      ? "1 service mounted"
      : remotes.length + " services mounted"
    return mountedCount + " of " + remotes.length + " mounted"
  }

  // ---------------------------------------------------------------- cursor

  function clampCursor() {
    if (cursorIndex >= rowCount) cursorIndex = Math.max(0, rowCount - 1)
    if (cursorIndex < 0) cursorIndex = 0
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (dy === 0) return
    cursorIndex = Math.max(0, Math.min(rowCount - 1, cursorIndex + dy))
    scrollCursorIntoView()
  }

  function activateCursor() {
    clampCursor()
    if (!rcloneInstalled) {
      installRclone()
      return
    }
    if (cursorIndex === connectIndex) {
      connectService()
      return
    }
    primaryAction(remotes[cursorIndex])
  }

  // Anything that opens a window elsewhere closes the panel first. The panel is
  // a layer surface holding exclusive keyboard focus, so leaving it up means
  // the terminal or file manager we just launched opens behind it and does not
  // take focus.
  function connectService() {
    if (!cloud) return
    close()
    cloud.connectService()
  }

  function installRclone() {
    if (!cloud) return
    close()
    cloud.installRclone()
  }

  function openInFiles(remote) {
    if (!cloud) return
    close()
    cloud.openInFiles(remote)
  }

  function configure(remote) {
    if (!cloud) return
    close()
    cloud.configure(remote)
  }

  function reconnect(remote) {
    if (!cloud) return
    close()
    cloud.reconnect(remote)
  }

  // What Enter (and a click on the row body) does, per state. Mounting is the
  // one action that keeps the panel up, because its result shows up here.
  function primaryAction(remote) {
    if (!remote || !cloud) return
    if (remote.state === "needs-auth") reconnect(remote)
    else if (remote.state === "mounted") openInFiles(remote)
    else cloud.mount(remote.name)
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollCursorIntoView() {
    if (cursorIndex < remoteColumn.children.length) scrollItemIntoView(remoteColumn.children[cursorIndex])
    else scrollItemIntoView(connectRow)
  }

  // ---------------------------------------------------------------- lifecycle

  function onOpened() {
    cursorActive = false
    cursorIndex = 0
    if (panelFlick) panelFlick.contentY = 0
    if (cloud) cloud.refresh(true)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function open() {
    openedFromHotkey = false
    root.controller.show()
    root.onOpened()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.onOpened()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  // Route panel switching through the widget, not this nested panel.
  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function")
      return bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  onRemotesChanged: clampCursor()

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { if (root.cloud) root.cloud.refresh(true); return "ok" }
    function connect(): string { if (root.cloud) root.cloud.connectService(); return "ok" }
  }

  // ---------------------------------------------------------------- surface

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") { if (root.cloud) root.cloud.refresh(true) }
        else if (t === "n" || t === "N") { if (root.cloud) root.cloud.connectService() }
        else if (t === "m" || t === "M") {
          if (root.cursorIndex < root.remotes.length && root.cloud)
            root.cloud.toggleMount(root.remotes[root.cursorIndex])
        }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: "Cloud"
            meta: root.heroMeta
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: Model.GLYPH_CLOUD
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            visible: text !== ""
            width: parent.width
            text: root.cloud
              ? (root.cloud.actionStatus !== "" ? root.cloud.actionStatus : root.cloud.lastError)
              : ""
            color: root.cloud && root.cloud.lastError !== "" && root.cloud.actionStatus === ""
              ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // rclone missing: nothing else on this panel can work, so it is the
          // only thing offered.
          ActionRow {
            visible: !root.rcloneInstalled
            width: parent.width
            glyph: Model.GLYPH_ALERT
            title: "Install rclone"
            subtitle: "Required to connect cloud storage"
            hasCursor: root.cursorActive && !root.rcloneInstalled
            onTriggered: root.installRclone()
          }

          Column {
            id: remoteColumn
            visible: root.rcloneInstalled && root.remotes.length > 0
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.rcloneInstalled ? root.remotes : []
              RemoteRow {
                required property var modelData
                required property int index
                width: remoteColumn.width
                remote: modelData
                rowIndex: index
              }
            }
          }

          Text {
            visible: root.rcloneInstalled && root.remotes.length === 0
            width: parent.width
            text: "Connect Google Drive, Dropbox or OneDrive to browse it in Files."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          PanelSeparator {
            visible: root.rcloneInstalled
            foreground: root.foreground
          }

          ActionRow {
            id: connectRow
            visible: root.rcloneInstalled
            width: parent.width
            glyph: Model.GLYPH_ADD
            title: "Connect a service…"
            subtitle: "Sign in and mount it as a folder"
            hasCursor: root.cursorActive && root.rcloneInstalled && root.cursorIndex === root.connectIndex
            onTriggered: root.connectService()
            onHoveredIn: {
              root.cursorActive = true
              root.cursorIndex = root.connectIndex
            }
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------- rows

  component ActionRow: CursorSurface {
    id: actionRow
    property string glyph: ""
    property string title: ""
    property string subtitle: ""
    signal triggered()
    signal hoveredIn()

    foreground: root.foreground
    implicitHeight: actionContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: actionRow.hoveredIn()
      onClicked: actionRow.triggered()
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        text: actionRow.glyph
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: actionContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: actionRow.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          visible: actionRow.subtitle !== ""
          text: actionRow.subtitle
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  component RemoteRow: CursorSurface {
    id: remoteRow
    property var remote: null
    property int rowIndex: 0

    readonly property string remoteState: remote ? String(remote.state || "stopped") : "stopped"
    readonly property bool isMounted: remoteState === "mounted"
    readonly property bool needsAuth: remoteState === "needs-auth"
    readonly property bool isFailed: remoteState === "failed"

    // Only trouble gets colour. A service that is simply switched off is not a
    // problem and should not read like one.
    readonly property color stateColor: {
      if (isFailed) return root.urgent
      if (needsAuth) return Color.accent
      return root.dim
    }

    hasCursor: root.cursorActive && root.cursorIndex === rowIndex
    foreground: root.foreground
    implicitHeight: remoteContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: {
        root.cursorActive = true
        root.cursorIndex = remoteRow.rowIndex
      }
      onClicked: root.primaryAction(remoteRow.remote)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        text: Model.stateGlyph(remoteRow.remoteState)
        color: remoteRow.stateColor
        opacity: remoteRow.isMounted ? 1.0 : 0.75
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: remoteContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: remoteRow.remote ? String(remoteRow.remote.label || remoteRow.remote.name) : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: Model.rowDetail(remoteRow.remote)
          color: remoteRow.isFailed ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      // Sign-in is the whole job when a service needs it, so it gets a word
      // rather than an icon nobody would guess the meaning of.
      Text {
        visible: remoteRow.needsAuth
        text: "Sign in"
        color: Color.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignVCenter
      }

      // Always present, so the choices made during setup stay changeable
      // without anyone having to discover a right-click.
      PanelActionButton {
        iconText: Model.GLYPH_SETTINGS
        tooltipText: "Settings"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.configure(remoteRow.remote)
      }

      PanelActionButton {
        visible: !remoteRow.needsAuth
        iconText: remoteRow.isMounted ? Model.GLYPH_OPEN : Model.GLYPH_MOUNTED
        tooltipText: remoteRow.isMounted ? "Open in Files" : "Mount now"
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: root.cloud && !root.cloud.busy
        Layout.alignment: Qt.AlignVCenter
        onClicked: {
          if (remoteRow.isMounted) root.openInFiles(remoteRow.remote)
          else if (root.cloud) root.cloud.mount(remoteRow.remote.name)
        }
      }
    }
  }
}
