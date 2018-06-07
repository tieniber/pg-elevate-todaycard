var MxApp = require("mendix-hybrid-app-base");

MxApp.onConfigReady(function(config) {
    // Perform any custom operations on the dojoConfig object here
    window.localStorage.setItem("mx-user-onboarded", window.localStorage.getItem("mx-user-onboarded") || !!0);
    window.dojoConfig.server.timeout = 30 * 1000;
});

MxApp.onClientReady(function(mx) {
    mx.session.logout = function() {
        return mx.session.sessionStore.remove()
            .then(function() {
                return new Promise(function(resolve, reject) {
                    window.localStorage.setItem("mx-user-finger", "false");
                    window.localStorage.setItem("mx-user-pin", "false");
                    window.localStorage.setItem("mx-user-token", "false");
                    console.log("killing session on the server");
                    mx.data.action({
                        params: {
                            actionname: "CustomAuthentication.KillSession",
                        },
                        callback: function() {
                            console.log("Session Killed on the server.")
                            resolve();
                        },
                        error: function(e) {
                            console.error(e);
                            reject();
                        }
                    })
                });
            });
    };
    window.localStorage.setItem("mx-user-token", !!0);
});

// Uncomment this function if you would like to control when app updates are performed
/*
MxApp.onAppUpdateAvailable(function(updateCallback) {
    // This function is called when a new version of your Mendix app is available.
    // Invoke the callback to trigger the app update mechanism.
});
*/