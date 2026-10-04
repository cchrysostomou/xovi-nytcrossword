import QtQuick 2.5
import QtQuick.Controls 2.5
import net.asivery.ApploadUtils
import net.asivery.CommandExecutor 1.0

Rectangle {
    id: app
    anchors.fill: parent
    color: "white"

    signal close
    function unloading() {}

    readonly property string runScript: "/home/root/xovi-nytcrossword/scripts/nytcrossword-run.sh"
    property string status: "Starting…"
    property string pendingAction: ""
    property bool busy: false
    property bool configured: false
    property string backendVersion: ""
    property string logLines: ""

    function appendLog(line) {
        logLines = (logLines ? logLines + "\n" : "") + line;
    }

    function run(arguments, action) {
        if (busy) return;
        busy = true;
        pendingAction = action;
        backend.output = "";
        backend.errorOutput = "";
        backend.arguments = [runScript].concat(arguments);
        appendLog("→ " + arguments.join(" "));
        if (!backend.startCommand(30000)) {
            busy = false;
            status = "Could not start backend command";
            appendLog("✕ could not start backend command");
        }
    }

    function finishCommand() {
        busy = false;
        var action = pendingAction;
        pendingAction = "";
        var result;
        try {
            result = JSON.parse(backend.output);
        } catch (error) {
            status = "Backend returned invalid output";
            appendLog("✕ " + (backend.errorOutput || backend.output || "no output"));
            return;
        }
        if (!result.ok) {
            status = result.message || result.error || "Command failed";
            appendLog("✕ " + (result.error || "error"));
            return;
        }
        appendLog("✓ " + action);
        if (action === "status") applyStatus(result);
    }

    function applyStatus(result) {
        backendVersion = result.version || "";
        configured = !!result.configured;
        status = configured
            ? "Ready (backend " + backendVersion + ")"
            : "Not configured: add NYT_S_COOKIE to /home/root/xovi-nytcrossword/config.env";
    }

    function loadStatus() {
        status = "Checking backend…";
        run(["status"], "status");
    }

    AsyncCommandExecutor {
        id: backend
        command: "sh"
        property string output: ""
        property string errorOutput: ""
        onStdOutAvailable: function(chunk) { output += chunk; }
        onStdErrAvailable: function(chunk) { errorOutput += chunk; }
        onRunningChanged: {
            if (!running && app.busy) app.finishCommand();
        }
    }

    Component.onCompleted: loadStatus()

    Column {
        anchors.fill: parent
        anchors.margins: 36
        spacing: 16

        Row {
            width: parent.width
            spacing: 18
            Text {
                text: "NYT Crossword"
                font.pixelSize: 46
                font.bold: true
                width: parent.width - 2 * 220 - 2 * 18
            }
            Rectangle {
                width: 220
                height: 64
                color: app.busy ? "#aaaaaa" : "black"
                Text { anchors.centerIn: parent; text: "Refresh"; color: "white"; font.pixelSize: 24 }
                MouseArea { anchors.fill: parent; enabled: !app.busy; onClicked: app.loadStatus() }
            }
            Rectangle {
                width: 220
                height: 64
                color: "white"
                border.color: "black"
                border.width: 3
                Text { anchors.centerIn: parent; text: "Close"; font.pixelSize: 24 }
                MouseArea { anchors.fill: parent; onClicked: app.close() }
            }
        }

        Text {
            width: parent.width
            text: app.status
            font.pixelSize: 22
            wrapMode: Text.WordWrap
        }

        Rectangle {
            width: parent.width
            height: parent.height - 64 - 22 - 3 * 16 - 40
            border.color: "black"
            border.width: 2
            Flickable {
                anchors.fill: parent
                anchors.margins: 12
                clip: true
                contentHeight: logText.paintedHeight
                Text {
                    id: logText
                    width: parent.width
                    text: app.logLines
                    font.pixelSize: 20
                    font.family: "monospace"
                    wrapMode: Text.WrapAnywhere
                }
            }
        }
    }
}
