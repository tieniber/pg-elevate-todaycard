Cordova Cookies Plugin
=======

Cordova plugin that allows you to clear cookies of the webview. This plugin is a fork of https://github.com/bez4pieci/Phonegap-Cookies-Plugin.git

## Installation

Cookies is compatible with [Cordova Plugman](https://github.com/apache/cordova-plugman) and ready for the [PhoneGap 3.0 CLI](http://docs.phonegap.com/en/3.0.0/guide_cli_index.md.html#The%20Command-line%20Interface_add_features), here's how it works with the CLI:

```
$ phonegap local plugin add https://github.com/dokoto/crosswalk-cookies.git
```

## Usage

```javascript
window.cookies.clear(function() {
	console.log('Cookies cleared!');
});
