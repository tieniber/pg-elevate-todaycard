package com.crosswalk.cookies;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaPlugin;
import org.json.JSONArray;
import org.json.JSONException;

import android.util.Log;
import org.xwalk.core.XWalkCookieManager;

public class Cookies extends CordovaPlugin {
    private final String TAG = "CookiesPlugin";
    private XWalkCookieManager CookieManager = new XWalkCookieManager();

    @Override
    public boolean execute(String action, JSONArray args, CallbackContext callbackContext) throws JSONException {
        if ("clear".equals(action)) {
            this.clear();
            callbackContext.success();
            return true;
        }
        return false;  // Returning false results in a "MethodNotFound" error.
    }

    public void clear() {
        Log.v(TAG, "XWalk-Clearing cookies...");
        CookieManager.removeAllCookie();
    }
}
