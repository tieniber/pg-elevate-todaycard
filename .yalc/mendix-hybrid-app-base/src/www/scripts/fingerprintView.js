"use strict";

import BPromise from "bluebird";
import SecureStore from "./secure-store";
import TokenStore from "./Token-store";
//var fingerprint = require("./fingerprint");

var tokenStore = new TokenStore(SecureStore);

export function verify() {
    return new Promise((resolve, reject) => {
        if (device.platform === "iOS") {
            window.plugins.touchid.isAvailable(
                function() {
                    window.plugins.touchid.verifyFingerprint(
                        'Scan your fingerprint please', // this will be shown in the native scanner popup
                        function(msg) {
                            resolve();
                        }, // success handler: fingerprint accepted
                        function(msg) {
                            deleteToken();
                            reject(new Error("Fingerprint verification failed"));
                        } // error handler with errorcode and localised reason
                    );
                }, // success handler: TouchID available
                function(msg) {
                    deleteToken();
                    reject(new Error("No Touch ID available"));
                } // error handler: no TouchID available
            );
        } else if (device.platform === "Android") {
            FingerprintAuth.isAvailable(androidIsAvailableSuccess, androidIsAvailableError);
        }

        function androidIsAvailableSuccess(result) {
            //console.log("FingerprintAuth available: " + JSON.stringify(result));
            var encryptConfig = {
                clientId: "mxApp",
                username: "",
                password: "",
                maxAttempts: 3,
                encryptNoAuth: false,
                dialogTitle: "Fingerprint authentication",
                dialogMessage: "Confirm fingerprint to continue",
                dialogHint: "Touch sensor"
            };

            if (result.isAvailable) {
                FingerprintAuth.encrypt(encryptConfig, androidEncryptSuccessCallback, androidEncryptFailureCallback);
            }
        }

        function androidIsAvailableError(message) {
            console.log("isAvailableError(): " + message);
            deleteToken();
        }

        function androidEncryptSuccessCallback(result) {
            if (result.withFingerprint) {
                console.log("Successful biometric authentication.");
                /*if (result.password) {
                    console.log("Successfully decrypted credential token.");
                    console.log("password: " + result.password);
                }*/
            } else if (result.withBackup) {
                console.log("Authenticated with backup password");
            }
            resolve();
        }

        function androidEncryptFailureCallback(error) {
            if (error === FingerprintAuth.ERRORS.FINGERPRINT_CANCELLED) {
                console.log("FingerprintAuth Dialog Cancelled!");
            } else {
                console.log("FingerprintAuth Error: " + error);
            }
            reject(new Error("Fingerprint verification failed"));
        }

        function deleteToken() {
            BPromise.all([
                tokenStore.remove(),
            ]).then(closeView);
        }

        function closeView() {
            if (callback) callback();
        }
    });
}