import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "sportsbar"
  ipcTarget: "sportsbar"
  manageIpc: false

  readonly property int maxTeams: 6
  // Direct settings.* read (not the setting() helper): QML's binding
  // dependency tracker doesn't follow property reads made inside a function
  // call, so a binding built on root.setting() never re-evaluates when
  // settings changes live. Matches how other first-party plugins (e.g.
  // Tailscale) read their settings inline for the same reason.
  readonly property bool colorizeTeams: root.settings.colorizeTeams !== false

  // Absolute path to the bundled backend script (bin/omarchy-sportsbar next
  // to this file). Resolved from this file's own URL rather than assumed on
  // $PATH so the plugin works from any clone location with no separate
  // install step -- required since `omarchy plugin add` only ever clones
  // this repo and never runs install hooks.
  readonly property string backendScript: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")) + "bin/omarchy-sportsbar"

  property var anchorItem: null
  property bool openedFromHotkey: false
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.refresh()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.refresh()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // Parsed `omarchy-sportsbar detail` output: {"teams":[{sport,teamId,
  // teamName,teamAbbrev,label,current,upcoming}, ...]}. Kept on failure so
  // stale data stays visible instead of blanking the popup.
  property var report: ({teams: []})
  readonly property var teamList: report.teams || []
  readonly property bool hasTeams: teamList.length > 0
  readonly property bool atMax: teamList.length >= maxTeams

  readonly property string tooltipText: {
    if (!hasTeams) return "Click to add a favorite team"
    var lines = []
    for (var i = 0; i < teamList.length; i++) lines.push(teamList[i].label || teamList[i].teamAbbrev || "")
    return lines.join("\n")
  }

  // State file drives the team list; watched so add/remove from the menu
  // updates the panel without a shell restart.
  property FileView stateFile: FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/sportsbar.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.refresh()
    onLoadFailed: root.report = ({teams: []})
  }

  function refresh() {
    if (!detailProc.running) detailProc.running = true
  }

  Process {
    id: detailProc
    command: [root.backendScript, "detail"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        try {
          root.report = JSON.parse(raw)
        } catch (e) {
          // Keep last-good report visible.
        }
      }
    }
  }

  function runAddTeam() {
    addTeamProc.running = true
  }

  Process {
    id: addTeamProc
    command: [root.backendScript, "add"]
    onExited: root.refresh()
  }

  property string removingKey: ""

  function runRemoveTeam(sport, teamId) {
    removingKey = sport + ":" + teamId
    removeTeamProc.command = [root.backendScript, "remove-direct", sport, teamId]
    removeTeamProc.running = true
  }

  Process {
    id: removeTeamProc
    onExited: {
      root.removingKey = ""
      root.refresh()
    }
  }

  // Auto-refresh; matches the backend's own cache TTL so this never fetches
  // more often than the cache would serve anyway.
  Timer {
    interval: 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: false
    onTriggered: root.refresh()
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: scroll.width
          spacing: 0

          // ---- No teams configured yet.
          Column {
            visible: !root.hasTeams
            width: parent.width
            spacing: Style.space(10)
            topPadding: Style.space(16)
            bottomPadding: Style.space(16)
            leftPadding: Style.space(16)
            rightPadding: Style.space(16)

            Text {
              text: "No favorite teams yet"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
            }
            Text {
              width: parent.width - Style.space(32)
              wrapMode: Text.WordWrap
              text: "Add up to " + root.maxTeams + " teams to see their scores and next games here."
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            AddTeamButton {
              bar: root.bar
              onAddRequested: root.runAddTeam()
            }
          }

          // ---- One card per favorite team.
          Repeater {
            model: root.teamList

            Column {
              id: card
              required property var modelData
              required property int index
              width: column.width

              readonly property var current: modelData.current || null
              readonly property var upcoming: modelData.upcoming || null
              readonly property bool removing: root.removingKey === (modelData.sport + ":" + modelData.teamId)
              // Team's real brand color, snapped to the nearest swatch in
              // the active theme (computed backend-side); falls back to the
              // bar's normal foreground when unset (e.g. older favorites
              // added before this existed) or when colorizeTeams is off.
              readonly property color accentColor: (root.colorizeTeams && modelData.color) ? Qt.color(modelData.color) : root.bar.foreground

              PanelSeparator {
                visible: card.index > 0
                foreground: root.bar.foreground
              }

              Item {
                width: parent.width
                height: heroRow.implicitHeight + Style.space(20)

                Rectangle {
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  anchors.topMargin: card.index > 0 ? 1 : 0
                  width: Style.space(3)
                  color: card.accentColor
                }

                Row {
                  id: heroRow
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(20)
                  anchors.right: removeButton.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(10)

                  // Team logo: ASCII art (plain text, no color codes) when the
                  // team was favorited with --ascii, otherwise the real logo
                  // loaded straight from ESPN's CDN. Blank for favorites added
                  // before this existed until the next detail refresh backfills
                  // logoUrl.
                  Item {
                    id: logoBox
                    width: Style.space(44)
                    height: Style.space(44)
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                      visible: !!card.modelData.logoAscii
                      anchors.centerIn: parent
                      text: card.modelData.logoAscii || ""
                      color: card.accentColor
                      font.family: "monospace"
                      font.pixelSize: 5
                      lineHeight: 0.85
                      lineHeightMode: Text.ProportionalHeight
                    }

                    Image {
                      visible: !card.modelData.logoAscii && !!card.modelData.logoUrl
                      anchors.centerIn: parent
                      width: parent.width
                      height: parent.height
                      source: card.modelData.logoUrl || ""
                      fillMode: Image.PreserveAspectFit
                      asynchronous: true
                      cache: true
                      smooth: true
                    }
                  }

                  Column {
                    width: parent.width - logoBox.width - heroRow.spacing - (scoreText.visible ? scoreText.implicitWidth + Style.space(14) : 0)
                    spacing: Style.space(2)

                    Text {
                      text: card.modelData.teamName || ""
                      color: card.accentColor
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.title
                      font.bold: true
                      elide: Text.ElideRight
                      width: parent.width
                    }
                    Text {
                      text: card.current
                        ? (card.current.state === "in" ? "Live · " : "")
                          + (card.current.isHome ? "vs " : "@ ") + (card.current.opponent || "") + " · " + (card.current.detail || "")
                        : "No recent game"
                      color: Qt.darker(root.bar.foreground, 1.4)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight
                      width: parent.width
                    }
                    Text {
                      visible: !!card.upcoming
                      text: card.upcoming
                        ? "Next: " + (card.upcoming.isHome ? "vs " : "@ ") + card.upcoming.opponent + " · "
                          + (card.upcoming.daysAway === 0 ? "Today" : card.upcoming.daysAway === 1 ? "Tomorrow" : "in " + card.upcoming.daysAway + " days")
                        : ""
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight
                      width: parent.width
                    }
                  }

                  Column {
                    id: scoreCol
                    visible: !!card.current
                    spacing: Style.space(2)

                    Text {
                      id: scoreText
                      text: card.current ? (card.current.teamScore || "0") + "-" + (card.current.opponentScore || "0") : ""
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.title
                      font.bold: true
                    }
                    Text {
                      visible: card.current && card.current.state === "post" && !!card.current.result
                      text: card.current ? (card.current.result === "W" ? "WIN" : card.current.result === "L" ? "LOSS" : "TIE") : ""
                      color: card.current && card.current.result === "W" ? Color.accent : Qt.darker(root.bar.foreground, 1.3)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      font.letterSpacing: 1
                    }
                  }
                }

                Rectangle {
                  id: removeButton
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(22)
                  height: Style.space(22)
                  radius: Style.cornerRadius
                  color: removeArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

                  Text {
                    anchors.centerIn: parent
                    text: card.removing ? "󰦖" : "✕"
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall

                    RotationAnimator on rotation {
                      running: card.removing
                      from: 0; to: 360
                      duration: 800
                      loops: Animation.Infinite
                    }
                  }

                  MouseArea {
                    id: removeArea
                    anchors.fill: parent
                    enabled: !card.removing
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.runRemoveTeam(card.modelData.sport, card.modelData.teamId)
                  }
                }
              }
            }
          }

          // ---- Add another team.
          Column {
            visible: root.hasTeams
            width: parent.width
            topPadding: Style.space(6)
            bottomPadding: Style.space(16)
            leftPadding: Style.space(16)

            PanelSeparator {
              width: parent.width - Style.space(16)
              foreground: root.bar.foreground
            }

            Item { width: 1; height: Style.space(10) }

            AddTeamButton {
              visible: !root.atMax
              bar: root.bar
              onAddRequested: root.runAddTeam()
            }

            Text {
              visible: root.atMax
              text: root.maxTeams + "/" + root.maxTeams + " teams tracked"
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }
      }
    }
  }

  component AddTeamButton: Rectangle {
    id: addBtn
    property QtObject bar: null
    signal addRequested()

    width: addLabel.implicitWidth + Style.space(24)
    height: addLabel.implicitHeight + Style.space(14)
    radius: Style.cornerRadius
    color: addArea.containsMouse ? Style.hoverFillFor(addBtn.bar.foreground, Color.accent) : Qt.rgba(addBtn.bar.foreground.r, addBtn.bar.foreground.g, addBtn.bar.foreground.b, 0.08)

    Text {
      id: addLabel
      anchors.centerIn: parent
      text: "Add Team"
      color: addBtn.bar.foreground
      font.family: addBtn.bar.fontFamily
      font.pixelSize: Style.font.body
    }

    MouseArea {
      id: addArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: addBtn.addRequested()
    }
  }
}
