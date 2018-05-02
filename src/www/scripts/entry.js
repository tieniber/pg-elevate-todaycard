var MxApp = require("mendix-hybrid-app-base");

MxApp.onConfigReady(function(config) {
    // Perform any custom operations on the dojoConfig object here
    window.localStorage.setItem("mx-user-onboarded", window.localStorage.getItem("mx-user-onboarded") || !!0);
});

MxApp.onClientReady(function(mx) {
    // mx.session.loadSessionData = function() {

    // };
    mx.session.logout = function() {
        return mx.session.sessionStore.remove()
            .then(function() {
                return new Promise(function(resolve, reject) {
                    window.localStorage.setItem("mx-user-finger", "false");
                    window.localStorage.setItem("mx-user-pin", "false");
                    console.log("killing session on the server");
                    window.mx.data.action({
                        params: {
                            actionname: "CustomAuthentication.KillSession",
                        },
                        callback: function() {
                            console.log("Session Killed on the server.")
                            resolve();
                        },
                        error: function(e) {
                            console.error(e);
                            resolve();
                        }
                    })
                });
            });
    };
});

// Uncomment this function if you would like to control when app updates are performed
/*
MxApp.onAppUpdateAvailable(function(updateCallback) {
    // This function is called when a new version of your Mendix app is available.
    // Invoke the callback to trigger the app update mechanism.
});
*/