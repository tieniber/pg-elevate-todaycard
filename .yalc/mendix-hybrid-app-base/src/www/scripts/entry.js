const MxApp = require("./app");
const Settings = require("./settings");

// Make sure to include the scheme (e.g. http://) in the URL.
document.addEventListener("deviceready", function() {
    // alert("hello yalc");
    Settings.loadJSON("settings.json", function(response) {
        let settings = JSON.parse(response);
        var userPin = localStorage.getItem("mx-user-pin") === "true",
            userFingerprint = localStorage.getItem("mx-user-finger") === "true",
            userToken = localStorage.getItem("mx-user-token") === "true";

        MxApp.initialize(settings.url, settings.enableOffline, settings.persistentSession.enabled,
            settings.persistentSession.forceSecurity, userPin, userFingerprint, userToken, settings.username,
            settings.password, settings.updateAsync);
    });
});

module.exports = MxApp;