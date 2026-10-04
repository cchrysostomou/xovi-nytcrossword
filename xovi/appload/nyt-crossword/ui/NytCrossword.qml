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
    property string status: "Starting..."
    property string pendingAction: ""
    property bool busy: false
    property bool configured: false
    property bool curlAvailable: false
    property bool mergerAvailable: false
    property bool brokerReady: false
    property bool initialized: false
    property string backendVersion: ""
    property string selectedPreset: "today"
    property var startDate: localToday()
    property var endDate: localToday()
    property int puzzleCount: 1
    property string destination: ""
    property string resultMessage: ""
    property string logLines: ""
    property bool settingsVisible: false
    property bool settingsLoaded: false
    property bool mergeRequired: false
    property bool rangeLoaded: false
    property int missingCount: 0
    property var rangeDates: []

    readonly property bool canImport:
        configured && curlAvailable && brokerReady &&
        (!mergeRequired || mergerAvailable) && rangeLoaded && missingCount > 0 && !busy

    function localToday() {
        var now = new Date();
        return new Date(now.getFullYear(), now.getMonth(), now.getDate(), 12, 0, 0);
    }

    function copyDate(value) {
        return new Date(value.getFullYear(), value.getMonth(), value.getDate(), 12, 0, 0);
    }

    function addDays(value, amount) {
        var changed = copyDate(value);
        changed.setDate(changed.getDate() + amount);
        return changed;
    }

    function isoDate(value) {
        function two(number) { return number < 10 ? "0" + number : "" + number; }
        return value.getFullYear() + "-" + two(value.getMonth() + 1) + "-" + two(value.getDate());
    }

    function displayDate(value) {
        var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
        return months[value.getMonth()] + " " + value.getDate() + ", " + value.getFullYear();
    }

    function nytPuzzleId(value) {
        var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
        var day = value.getDate() < 10 ? "0" + value.getDate() : "" + value.getDate();
        var year = ("" + value.getFullYear()).slice(-2);
        return months[value.getMonth()] + day + year;
    }

    function puzzleIds() {
        var ids = [];
        var cursor = copyDate(startDate);
        var end = copyDate(endDate);
        while (cursor.getTime() <= end.getTime() && ids.length < 32) {
            ids.push(nytPuzzleId(cursor));
            cursor = addDays(cursor, 1);
        }
        return ids.join(",");
    }

    function selectPreset(preset) {
        var today = localToday();
        selectedPreset = preset;
        endDate = today;
        if (preset === "week") {
            startDate = addDays(today, -today.getDay());
        } else if (preset === "month") {
            startDate = new Date(today.getFullYear(), today.getMonth(), 1, 12, 0, 0);
        } else if (preset === "last-week") {
            endDate = addDays(today, -today.getDay() - 1);
            startDate = addDays(endDate, -6);
        } else if (preset === "last-month") {
            startDate = new Date(today.getFullYear(), today.getMonth() - 1, 1, 12, 0, 0);
            endDate = new Date(today.getFullYear(), today.getMonth(), 0, 12, 0, 0);
        } else {
            startDate = today;
        }
        requestPreview();
    }

    function adjustStart(amount) {
        selectedPreset = "custom";
        var changed = addDays(startDate, amount);
        if (changed.getTime() <= endDate.getTime() &&
                Math.round((endDate.getTime() - changed.getTime()) / 86400000) < 31) {
            startDate = changed;
            requestPreview();
        }
    }

    function adjustEnd(amount) {
        selectedPreset = "custom";
        var changed = addDays(endDate, amount);
        var today = localToday();
        if (changed.getTime() >= startDate.getTime() &&
                changed.getTime() <= today.getTime() &&
                Math.round((changed.getTime() - startDate.getTime()) / 86400000) < 31) {
            endDate = changed;
            requestPreview();
        }
    }

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
        if (action === "import") {
            status = "Downloading and importing " + puzzleCount +
                     (puzzleCount === 1 ? " puzzle..." : " puzzles...");
        }
        appendLog("> " + action);
        if (!backend.startCommand(action === "import" ? 180000 : 30000)) {
            busy = false;
            status = "Could not start backend command";
            appendLog("x could not start backend command");
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
            appendLog("x " + (backend.errorOutput || backend.output || "no output"));
            return;
        }
        if (!result.ok) {
            status = result.message || result.error || "Command failed";
            resultMessage = "";
            appendLog("x " + (result.error || "error"));
            return;
        }
        appendLog("ok " + action);
        if (action === "settings" || action === "settings-apply") {
            settingsLoaded = true;
            folderInput.text = result.folder;
            timeoutInput.text = result.broker_timeout;
            configured = !!result.configured;
            cookieInput.text = "";
            status = action === "settings-apply" ? "Settings saved" : "Settings loaded";
            if (action === "settings-apply") {
                settingsVisible = false;
                loadStatus();
            }
        } else if (action === "status") {
            applyStatus(result);
        } else if (action === "view") {
            rangeLoaded = true;
            puzzleCount = result.count;
            missingCount = result.missing_count;
            rangeDates = result.dates;
            mergeRequired = !!result.merge_required;
            destination = result.dates.map(function(day) { return day.destination; })
                .filter(function(value, index, values) { return values.indexOf(value) === index; }).join("\n");
            status = result.present_count + " present; " + missingCount + " missing";
        } else if (action === "import") {
            resultMessage = "Imported " + result.count +
                (result.count === 1 ? " puzzle" : " puzzles") +
                " into " + result.documents.length +
                (result.documents.length === 1 ? " weekly PDF" : " weekly PDFs");
            appendLog(resultMessage);
            requestPreview();
        }
    }

    function readinessMessage() {
        if (!configured) return "Open Settings to save your NYT session cookie";
        if (!curlAvailable) return "A TLS-capable curl binary is required";
        if (!brokerReady) return "The XOVI message broker is not ready";
        if (mergeRequired && !mergerAvailable) return "Install qpdf or mutool for multi-day imports";
        return "Ready";
    }

    function applyStatus(result) {
        backendVersion = result.version || "";
        configured = !!result.configured;
        curlAvailable = !!result.curl_available;
        mergerAvailable = !!result.merger_available;
        brokerReady = !!result.broker_ready;
        status = readinessMessage();
        if (!initialized) {
            initialized = true;
            selectPreset("today");
        } else {
            requestPreview();
        }
    }

    function loadStatus() {
        status = "Checking backend...";
        run(["status"], "status");
    }

    function requestPreview() {
        resultMessage = "";
        rangeLoaded = false;
        rangeDates = [];
        run(["view", isoDate(startDate), isoDate(endDate), puzzleIds()], "view");
    }

    function importPuzzles() {
        if (!canImport) return;
        resultMessage = "";
        run(["import-missing", isoDate(startDate), isoDate(endDate), puzzleIds()], "import");
    }

    function openSettings() {
        settingsLoaded = false;
        settingsVisible = true;
        cookieInput.text = "";
        run(["settings"], "settings");
    }

    function saveSettings() {
        var folder = folderInput.text;
        var cookie = cookieInput.text;
        if (/[\r\n]/.test(folder + cookie) ||
                !/^[1-9][0-9]{0,2}$/.test(timeoutInput.text) ||
                Number(timeoutInput.text) > 300) {
            status = "Use single-line values and a broker wait of 1-300 seconds";
            return;
        }
        busy = true;
        var request = new XMLHttpRequest();
        request.open("PUT", "file:///home/root/xovi-nytcrossword/state/settings-draft.env");
        request.onreadystatechange = function() {
            if (request.readyState !== XMLHttpRequest.DONE) return;
            busy = false;
            cookieInput.text = "";
            if (request.status !== 0 && (request.status < 200 || request.status >= 300)) {
                status = "Could not write the private settings draft";
                appendLog("x settings draft write failed");
                return;
            }
            run(["settings-apply"], "settings-apply");
        };
        request.send("CROSSWORD_FOLDER=" + folder + "\nBROKER_TIMEOUT_S=" +
                     timeoutInput.text + "\nNYT_S_COOKIE=" + cookie + "\n");
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
        id: mainPage
        visible: !app.settingsVisible
        anchors.fill: parent
        anchors.margins: 30
        spacing: 14

        Row {
            width: parent.width
            spacing: 14
            Text {
                text: "NYT Crossword"
                font.pixelSize: 42
                font.bold: true
                width: parent.width - 3 * 150 - 3 * 14
            }
            Rectangle {
                width: 150
                height: 58
                color: app.busy ? "#aaaaaa" : "black"
                Text { anchors.centerIn: parent; text: "Settings"; color: "white"; font.pixelSize: 22 }
                MouseArea { anchors.fill: parent; enabled: !app.busy; onClicked: app.openSettings() }
            }
            Rectangle {
                width: 150
                height: 58
                color: app.busy ? "#aaaaaa" : "black"
                Text { anchors.centerIn: parent; text: "Refresh"; color: "white"; font.pixelSize: 22 }
                MouseArea { anchors.fill: parent; enabled: !app.busy; onClicked: app.loadStatus() }
            }
            Rectangle {
                width: 150
                height: 58
                color: "white"
                border.color: "black"
                border.width: 3
                Text { anchors.centerIn: parent; text: "Close"; font.pixelSize: 22 }
                MouseArea { anchors.fill: parent; enabled: !app.busy; onClicked: app.close() }
            }

        }

        Text {
            width: parent.width
            text: app.status
            font.pixelSize: 21
            wrapMode: Text.WordWrap
        }

        Row {
            width: parent.width
            spacing: 12
            Repeater {
                model: [
                    { key: "today", label: "Today" },
                    { key: "week", label: "This Week" },
                    { key: "month", label: "This Month" },
                    { key: "last-week", label: "Last Week" },
                    { key: "last-month", label: "Last Month" }
                ]
                Rectangle {
                    width: (parent.width - 4 * 12) / 5
                    height: 64
                    color: app.selectedPreset === modelData.key ? "black" : "white"
                    border.color: "black"
                    border.width: 3
                    Text {
                        anchors.centerIn: parent
                        text: modelData.label
                        color: app.selectedPreset === modelData.key ? "white" : "black"
                        font.pixelSize: 20
                    }
                    MouseArea {
                        anchors.fill: parent
                        enabled: !app.busy
                        onClicked: app.selectPreset(modelData.key)
                    }

                }
            }
        }

        Rectangle {
            width: parent.width
            height: 220
            border.color: "black"
            border.width: 2
            Column {
                anchors.fill: parent
                anchors.margins: 14
                spacing: 12
                Text {
                    text: app.puzzleCount + (app.puzzleCount === 1 ? " puzzle" : " puzzles") +
                          "  |  " + app.displayDate(app.startDate) +
                          (app.startDate.getTime() === app.endDate.getTime()
                           ? "" : " through " + app.displayDate(app.endDate))
                    font.pixelSize: 22
                    font.bold: true
                }
                Flickable {
                    width: parent.width
                    height: 65
                    clip: true
                    contentHeight: destinationsText.paintedHeight
                    Text {
                        id: destinationsText
                        width: parent.width
                        text: app.destination ? "Destination: " + app.destination : "Calculating destination..."
                        font.pixelSize: 19
                        wrapMode: Text.WordWrap
                    }
                }
                Row {
                    spacing: 12
                    Text { text: "Start"; font.pixelSize: 20; width: 70; anchors.verticalCenter: parent.verticalCenter }
                    Rectangle {
                        width: 60; height: 52; color: "white"; border.color: "black"; border.width: 2
                        Text { anchors.centerIn: parent; text: "-"; font.pixelSize: 28 }
                        MouseArea { anchors.fill: parent; enabled: !app.busy; onClicked: app.adjustStart(-1) }
                    }
                    Text {
                        text: app.isoDate(app.startDate)
                        font.pixelSize: 21
                        width: 150
                        horizontalAlignment: Text.AlignHCenter
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Rectangle {
                        width: 60; height: 52; color: "white"; border.color: "black"; border.width: 2
                        Text { anchors.centerIn: parent; text: "+"; font.pixelSize: 28 }
                        MouseArea { anchors.fill: parent; enabled: !app.busy; onClicked: app.adjustStart(1) }
                    }
                    Text { text: "End"; font.pixelSize: 20; width: 55; anchors.verticalCenter: parent.verticalCenter }
                    Rectangle {
                        width: 60; height: 52; color: "white"; border.color: "black"; border.width: 2
                        Text { anchors.centerIn: parent; text: "-"; font.pixelSize: 28 }
                        MouseArea { anchors.fill: parent; enabled: !app.busy; onClicked: app.adjustEnd(-1) }
                    }
                    Text {
                        text: app.isoDate(app.endDate)
                        font.pixelSize: 21
                        width: 150
                        horizontalAlignment: Text.AlignHCenter
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Rectangle {
                        width: 60; height: 52; color: "white"; border.color: "black"; border.width: 2
                        Text { anchors.centerIn: parent; text: "+"; font.pixelSize: 28 }
                        MouseArea { anchors.fill: parent; enabled: !app.busy; onClicked: app.adjustEnd(1) }
                    }
                }
            }
        }

        Rectangle {
            width: parent.width
            height: 180
            border.color: "#777777"
            Flickable {
                anchors.fill: parent
                anchors.margins: 10
                clip: true
                contentHeight: inventoryText.paintedHeight
                Text {
                    id: inventoryText
                    width: parent.width
                    font.pixelSize: 19
                    wrapMode: Text.WordWrap
                    text: app.rangeLoaded ? app.rangeDates.map(function(day) {
                        return day.date + (day.files.length ? "  Present: " +
                            day.files.map(function(file) { return file.name; }).join(", ") : "  Missing");
                    }).join("\n") : "Checking the library for selected dates..."
                }
            }
        }

        Rectangle {
            width: parent.width
            height: 68
            color: app.canImport ? "black" : "#aaaaaa"
            Text {
                anchors.centerIn: parent
                text: app.busy && app.pendingAction === "import" ? "Importing..." :
                    "Download missing (" + app.missingCount + ")"
                color: "white"
                font.pixelSize: 25
                font.bold: true
            }
            MouseArea {
                anchors.fill: parent
                enabled: app.canImport
                onClicked: app.importPuzzles()
            }
        }

        Text {
            width: parent.width
            text: app.resultMessage
            visible: text !== ""
            font.pixelSize: 21
            font.bold: true
            wrapMode: Text.WordWrap
        }

        Rectangle {
            width: parent.width
            height: Math.max(90, parent.height - 58 - 25 - 64 - 220 - 180 - 68 - 8 * 14 - 35)
            border.color: "#777777"
            border.width: 1
            Flickable {
                anchors.fill: parent
                anchors.margins: 10
                clip: true
                contentHeight: logText.paintedHeight
                Text {
                    id: logText
                    width: parent.width
                    text: app.logLines
                    font.pixelSize: 17
                    font.family: "monospace"
                    wrapMode: Text.WrapAnywhere
                }
            }
        }
    }
    Column {
        id: settingsPage
        visible: app.settingsVisible
        anchors.fill: app
        anchors.margins: 30
        spacing: 20
        Text { text: "NYT Crossword Settings"; font.pixelSize: 36; font.bold: true }
        Text { text: app.status; width: parent.width; wrapMode: Text.WordWrap; font.pixelSize: 21 }
        Text { text: "NYT-S session cookie"; font.pixelSize: 24 }
        TextField {
            id: cookieInput
            width: parent.width
            height: 64
            font.pixelSize: 22
            echoMode: TextInput.Password
            enabled: !app.busy
            placeholderText: app.configured ? "Saved cookie: leave blank to keep it" : "Enter the NYT-S cookie value"
            inputMethodHints: Qt.ImhHiddenText | Qt.ImhNoPredictiveText
        }
        Text {
            text: "Use the NYT-S value from your signed-in NYT browser session, not your account password."
            width: parent.width
            wrapMode: Text.WordWrap
            font.pixelSize: 19
        }
        Text { text: "Destination library folder"; font.pixelSize: 24 }
        TextField {
            id: folderInput
            width: parent.width
            height: 64
            font.pixelSize: 22
            enabled: !app.busy
            placeholderText: "/Crosswords"
        }
        Text { text: "Broker wait limit (seconds, 1-300)"; font.pixelSize: 24 }
        TextField {
            id: timeoutInput
            width: parent.width
            height: 64
            font.pixelSize: 22
            enabled: !app.busy
            inputMethodHints: Qt.ImhDigitsOnly
        }
        Row {
            spacing: 20
            Button { text: "Save"; enabled: !app.busy && app.settingsLoaded; onClicked: app.saveSettings() }
            Button {
                text: "Cancel"
                enabled: !app.busy
                onClicked: {
                    cookieInput.text = "";
                    app.settingsVisible = false;
                    app.loadStatus();
                }
            }
        }
    }
}
