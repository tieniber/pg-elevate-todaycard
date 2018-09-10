
(function _wk_xhr_proxy() {
    if (!window.webkit.messageHandlers) {
        return;
    }

    var xhrMessager = window.webkit.messageHandlers.xhr;
    var loc = window.location.protocol;
    if (!xhrMessager || loc !== 'file:') {
        return;
    }

    var originalInstanceKey = '__wk_original';

    var defaultHeaders = {
        "User-Agent": navigator.userAgent
    };

    // Adapted from zone.js
    var OriginalClass = window.XMLHttpRequest;

    if (!OriginalClass) {
        console.error('XMLHttpRequest does not exist!??');
        return;
    }

    var XHRProxy = function () {
        this.__fakeData = null;
        this.__headers = null;
        this.__tempFiles = null;
        this[originalInstanceKey] = new OriginalClass();
    };

    var instance = new OriginalClass(function () {});

    var prop;
    for (prop in instance) {
        (function (prop) {
            if (typeof instance[prop] === 'function') {
                XHRProxy.prototype[prop] = function () {
                    return this[originalInstanceKey][prop].apply(this[originalInstanceKey], arguments);
                };
            } else {
                Object.defineProperty(XHRProxy.prototype, prop, {
                    enumerable: true,
                    configurable: true,
                    set: function (fn) {
                        this[originalInstanceKey][prop] = fn;
                    },
                    get: function () {
                        var v = this.__get(prop);
                        if (v !== undefined) {
                            return v;
                        }
                        return this[originalInstanceKey][prop];
                    }
                });
            }
        }(prop));
    }

    for (prop in OriginalClass) {
        if (prop !== 'prototype' && OriginalClass.hasOwnProperty(prop)) {
            XHRProxy[prop] = OriginalClass[prop];
        }
    }

    // Patch XML class
    XHRProxy.prototype.open = function _wk_open(method, url, async) {
        if (useNativeRequest(url)) {
            console.debug("WK intercepted XHR:", url);
            this.__set('readyState', 1); // OPENED
            this.__set('status', 0);
            this.__set('responseText', '');
            this.__set('interceptedURL', url);
            this.__set('method', method);

            this.__fireEvent('Event', 'readystatechange');

            if (async === false) {
                throw new Error("wk does not support sync XHR.");
            }
        }

        return this[originalInstanceKey].open.apply(this[originalInstanceKey], arguments);
    };

    XHRProxy.prototype.send = function _wk_send(data) {
        if (this.__fakeData) {
            this.__set('readyState', 3);
            //this.__fireEvent('ProgressEvent', 'loadstart');
            this.__fireEvent('Event', 'readystatechange');
            var url = this.__get('interceptedURL');
            var method = this.__get('method');
            var headers = this.__getHeaders();

            if (data instanceof window.FormData) {
                var splittedformData = data.__entries.reduce(function(acc, entry) {
                    if (entry.fileName) {
                        acc.files.push(entry);
                    } else {
                        acc.data.push(entry);
                    }

                    return acc;
                }, {
                    data: [],
                    files:[]
                });

                writeBlobEntries(splittedformData.files).then(function(savedBlobEntries) {
                    this.__tempFiles = savedBlobEntries.map(function(blobEntry) {
                        return blobEntry.fileEntry;
                    });

                    scheduleXHRRequest(this, method, url, headers, {
                        data: splittedformData.data,
                        files: savedBlobEntries.map(function (blobEntry) {
                            return {
                                name: blobEntry.name,
                                fileName: blobEntry.fileName,
                                fileUrl: blobEntry.fileEntry.toURL()
                            };
                        })
                    });
                }.bind(this));
            } else {
                scheduleXHRRequest(this, method, url, headers, data);
            }
        } else {
            var original = this[originalInstanceKey];
            original.send.apply(original, arguments);
        }
    };

    XHRProxy.prototype.setRequestHeader = function(header, value) {
        if (this.__fakeData) {
            return this.__setHeader(header, value);
        }
        var original = this[originalInstanceKey];
        return original.setRequestHeader.apply(original, arguments);
    };

    XHRProxy.prototype.addEventListener = function _wk_addEventListener(eventName, callback) {
        console.debug('_wk_addEventListener (WIP!)', eventName);
        var original = this[originalInstanceKey];
        return original.addEventListener.apply(original, arguments);
    };

    XHRProxy.prototype.removeEventListener = function _wk_removeEventListener(eventName, callback) {
        console.debug('_wk_removeEventListener (WIP!)', eventName);
        var original = this[originalInstanceKey];
        return original.removeEventListener.apply(original, arguments);
    };

    XHRProxy.prototype.__fireEvent = function _wk_fire(type, name) {
        var event = document.createEvent(type);
        event.initEvent(name, false, false);
        this.dispatchEvent(event);
    };

    XHRProxy.prototype.__set = function _wk_set(key, value) {
        if (!this.__fakeData) {
            this.__fakeData = {};
        }
        this.__fakeData['__' + key] = value;
    };

    XHRProxy.prototype.__get = function _wk_get(key) {
        if (this.__fakeData) {
            return this.__fakeData['__' + key];
        }
    };

    XHRProxy.prototype.__setHeader = function _wk_set_header(header, value) {
        if (!this.__headers) {
            this.__headers = {};
        }
        this.__headers[header] = value;
    };

    XHRProxy.prototype.__getHeaders = function _wk_get_headers() {
        return this.__headers;
    };

    var FormDataProxy = function() {
        this.__entries = [];
    };

    FormDataProxy.prototype.append = function(name, value, fileName) {
        if (value instanceof Blob) {
            fileName = fileName || value.name || "blob";
        }

        this.__entries.push({
            name: name,
            value: value,
            fileName: fileName
        });
    };

    var reqId = 1;
    var requests = {};

    function scheduleXHRRequest(context, method, url, requestHeaders, data) {
        requests[reqId] = context;

        xhrMessager.postMessage(JSON.stringify({
            id: reqId,
            method: method,
            url: url,
            headers: Object.assign({}, defaultHeaders, requestHeaders),
            data: data || ""
        }));
        reqId++;
    }

    function writeBlobEntries(entries) {
        return Promise.all(entries.map(function(entry) {
            return writeBlob(entry.value).then(function(fileEntry) {
                return {
                    name: entry.name,
                    fileName: entry.fileName,
                    fileEntry: fileEntry
                };
            });
        }));
    }

    var sequence = 0;
    function writeBlob(blob) {
        return new Promise(function(resolve, reject) {
            window.resolveLocalFileSystemURL(cordova.file.tempDirectory, function(dir) {
                var fileName = "wkwebview_upload_" + (+new Date()) + sequence++;
                dir.getFile(fileName, { create: true }, function(fileEntry) {
                    fileEntry.createWriter(function(fileWriter) {
                        var fileSize = blob.size;
                        var blockSize = 1 * 1024 * 1024;
                        var written = 0;

                        function writeBlock() {
                            var sz = Math.min(blockSize, fileSize - written);
                            var block = blob.slice(written, written + sz);

                            fileWriter.seek(written);
                            fileWriter.write(block);
                        }

                        fileWriter.onwriteend = function(e) {
                            written = e.target.length;
                            if (written < fileSize) {
                                writeBlock();
                            } else {
                                resolve(fileEntry);
                            }
                        };
                        fileWriter.onerror = reject;

                        writeBlock();
                    });
                }, reject);
            }, reject);
        });
    }

    function handleXHRResponse(id, status, body) {
        var context = requests[id];
        if (!context) {
            console.error("Context not found: ", id);
            return;
        }
        requests[id] = null;

        if (context.__tempFiles) {
            context.__tempFiles.forEach(function(fileEntry) {
                fileEntry.remove();
            });
        }

        context.__set('readyState', 4);
        context.__set('status', status);
        context.__set('responseText', body);
        context.__set('response', processResponse(context.responseType, body));

        context.__fireEvent('Event', 'readystatechange');

        if (status === 0) {
            context.__fireEvent('UIEvent', 'error');
        } else {
            context.__fireEvent('UIEvent', 'load');
        }
        //context.__fireEvent('ProgressEvent', 'loadend');
    }

    function useNativeRequest(url) {
        return (!(/^[a-zA-Z0-9]+:\/\//.test(url)) || /^http(s)?|file:\/\//.test(url));
    }

    function processResponse(type, data) {
        var result = null;
        type = type || "text";
        switch(type) {
            case "text":
                result = data;
                break;
            case "json":
                try {
                    result = JSON.parse(data);
                } catch(e) {}
                break;
            default:
                console.error("Unsupported reponseType " + type);
        }
        return result;
    }

    window.handleXHRResponse = handleXHRResponse;
    window.XMLHttpRequest = XHRProxy;
    window.FormData = FormDataProxy;

    console.debug("XHR polyfill injected!");
})();
