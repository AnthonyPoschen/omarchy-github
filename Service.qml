import QtQuick
import Quickshell
import Quickshell.Io

// GitHub dashboard data service. The helper owns API pagination and aggregation;
// this item schedules it and exposes one stable, defensive model to the panel.
Item {
    id: root

    property var settings: ({
    })
    property bool loading: false
    property string state: "loading"
    property string message: "Loading GitHub…"
    property string login: ""
    property string fetchedAt: ""
    property var notifications: []
    property var reviewRequests: []
    property var assignedIssues: []
    property var myPullRequests: []
    property int myPullRequestsTotal: 0
    property var actions: []
    property var failedActions: []
    property var repositories: []
    property var warnings: []
    property var rateLimit: null
    property string _stdout: ""
    property string _stderr: ""
    property bool refreshQueued: false
    property string markingNotificationId: ""
    property string notificationActionStatus: ""
    property string _markStdout: ""
    property string _markStderr: ""
    readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 900, 60, 3600)
    readonly property int unreadCount: notifications.length
    readonly property int actionCount: actions.length
    // A broken check on your own pull request is the kind of thing the bar icon
    // exists to surface, so it counts toward the alarming state. Drafts are
    // excluded: a red check on work you have not offered up yet is expected,
    // and it would leave the icon permanently lit.
    readonly property int failingPullRequestCount: myPullRequests.filter(function(item) {
        return !item.draft && root.isBrokenCheck(item.checks);
    }).length
    readonly property bool alarming: unreadCount > 0 || actionCount > 0 || reviewRequests.length > 0 || failingPullRequestCount > 0

    // StatusCheckRollup groupings live here so the alarming count, the row label
    // and the row glyph cannot drift apart when a state is reclassified.
    function isBrokenCheck(checks) {
        var value = String(checks || "");
        return value === "FAILURE" || value === "ERROR";
    }

    function isRunningCheck(checks) {
        var value = String(checks || "");
        return value === "PENDING" || value === "EXPECTED";
    }

    function setting(name, fallback) {
        var value = settings ? settings[name] : undefined;
        return value === undefined || value === null ? fallback : value;
    }

    function intSetting(name, fallback, minimum, maximum) {
        var value = parseInt(String(setting(name, fallback)), 10);
        if (!isFinite(value))
            value = fallback;

        return Math.max(minimum, Math.min(maximum, value));
    }

    function boolSetting(name, fallback) {
        var value = setting(name, fallback);
        if (value === true || value === false)
            return value;

        var text = String(value).toLowerCase();
        return text === "true" || text === "yes" || text === "on" || text === "1";
    }

    function actionMode() {
        var value = String(setting("actionScanBehavior", "Recent repositories")).toLowerCase();
        if (value === "off")
            return "off";

        if (value.indexOf("all") === 0)
            return "all";

        return "recent";
    }

    function helperPath() {
        return Qt.resolvedUrl("omarchy-github-fetch").toString().replace(/^file:\/\//, "");
    }

    function command() {
        return [helperPath(), "--include-archived", boolSetting("includeArchived", false) ? "true" : "false", "--include-forks", boolSetting("includeForks", false) ? "true" : "false", "--include-archived-reviews", boolSetting("includeArchivedReviewRequests", false) ? "true" : "false", "--include-draft-reviews", boolSetting("includeDraftReviewRequests", false) ? "true" : "false", "--action-scan", actionMode(), "--action-repo-limit", String(intSetting("actionScanRepoLimit", 15, 5, 200)), "--concurrency", String(intSetting("actionScanConcurrency", 6, 1, 12)), "--failed-days", String(intSetting("failedActionDays", 7, 1, 30)), "--failed-limit", String(intSetting("failedActionLimit", 20, 1, 100))];
    }

    function refresh() {
        if (fetchProcess.running) {
            refreshQueued = true;
            return ;
        }
        loading = true;
        _stdout = "";
        _stderr = "";
        fetchProcess.command = command();
        fetchProcess.running = true;
    }

    function apply(raw) {
        try {
            var data = JSON.parse(String(raw || ""));
            state = String(data.state || "error");
            message = String(data.message || "");
            login = String(data.login || "");
            fetchedAt = String(data.fetchedAt || "");
            notifications = Array.isArray(data.notifications) ? data.notifications : [];
            reviewRequests = Array.isArray(data.reviewRequests) ? data.reviewRequests : [];
            assignedIssues = Array.isArray(data.assignedIssues) ? data.assignedIssues : [];
            myPullRequests = Array.isArray(data.myPullRequests) ? data.myPullRequests : [];
            myPullRequestsTotal = Number(data.myPullRequestsTotal) || myPullRequests.length;
            actions = Array.isArray(data.actions) ? data.actions : [];
            failedActions = Array.isArray(data.failedActions) ? data.failedActions : [];
            repositories = Array.isArray(data.repositories) ? data.repositories : [];
            warnings = Array.isArray(data.warnings) ? data.warnings : [];
            rateLimit = data.rateLimit || null;
        } catch (error) {
            state = "error";
            message = "GitHub returned an unreadable response.";
            warnings = [String(error)];
        }
    }

    function markNotificationRead(id) {
        var value = String(id || "");
        if (value === "" || markProcess.running)
            return ;

        markingNotificationId = value;
        notificationActionStatus = "Marking notification read…";
        _markStdout = "";
        _markStderr = "";
        markProcess.command = [helperPath(), "--mark-notification-read", value];
        markProcess.running = true;
    }

    visible: false

    Timer {
        interval: root.refreshIntervalSec * 1000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    Timer {
        id: actionStatusTimer

        interval: 3000
        repeat: false
        onTriggered: root.notificationActionStatus = ""
    }

    Process {
        id: fetchProcess

        running: false
        command: []
        onExited: function(exitCode) {
            root.loading = false;
            var stdout = String(output.text || root._stdout || "");
            var stderr = String(errors.text || root._stderr || "").trim();
            if (stdout.trim() !== "") {
                root.apply(stdout);
            } else {
                root.state = "error";
                root.message = stderr !== "" ? stderr : "GitHub data refresh failed.";
            }
            if (root.refreshQueued) {
                root.refreshQueued = false;
                Qt.callLater(root.refresh);
            }
        }

        stdout: StdioCollector {
            id: output

            waitForEnd: true
            onStreamFinished: root._stdout = text
        }

        stderr: StdioCollector {
            id: errors

            waitForEnd: true
            onStreamFinished: root._stderr = text
        }

    }

    Process {
        id: markProcess

        running: false
        command: []
        onExited: function(exitCode) {
            var response = null;
            try {
                response = JSON.parse(String(markOutput.text || root._markStdout || ""));
            } catch (error) {
            }
            if (exitCode === 0 && response && response.state === "ready") {
                var markedId = root.markingNotificationId;
                root.notifications = root.notifications.filter(function(item) {
                    return String(item.id || "") !== markedId;
                });
                root.notificationActionStatus = "Notification marked read.";
            } else {
                root.notificationActionStatus = response && response.message ? String(response.message) : String(markErrors.text || root._markStderr || "Could not mark notification read.").trim();
            }
            root.markingNotificationId = "";
            actionStatusTimer.restart();
        }

        stdout: StdioCollector {
            id: markOutput

            waitForEnd: true
            onStreamFinished: root._markStdout = text
        }

        stderr: StdioCollector {
            id: markErrors

            waitForEnd: true
            onStreamFinished: root._markStderr = text
        }

    }

}
