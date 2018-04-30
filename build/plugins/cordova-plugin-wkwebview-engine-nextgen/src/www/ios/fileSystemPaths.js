var exec = require('cordova/exec');
var channel = require('cordova/channel');

module.exports.storageDir = null;

channel.waitForInitialization('wkwebviewFileSystemPathsReady');
channel.onCordovaReady.subscribe(function() {
    function after(path) {
        module.exports.storageDir = path;
        channel.initializationComplete('wkwebviewFileSystemPathsReady');
    }

    exec(after, null, 'CDVWKWebViewEngine', 'requestStoragePath', []);
});
