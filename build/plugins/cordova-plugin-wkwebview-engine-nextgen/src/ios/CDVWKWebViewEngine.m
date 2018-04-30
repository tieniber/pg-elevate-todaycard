/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

#import "CDVWKWebViewEngine.h"
#import "CDVWKWebViewUIDelegate.h"
#import <Cordova/NSDictionary+CordovaPreferences.h>

#import <objc/message.h>

#define CDV_BRIDGE_NAME @"cordova"
#define CDV_IONIC_WK @"xhr"
#define CDV_WKWEBVIEW_FILE_URL_LOAD_SELECTOR @"loadFileURL:allowingReadAccessToURL:"
#define STORAGEDIR @"storage"

@interface CDVWKWebViewEngine ()
{
    NSOperationQueue *fileQueue;
    NSURLSession *urlSession;
}

@property (nonatomic, strong, readwrite) UIView* engineWebView;
@property (nonatomic, strong, readwrite) id <WKUIDelegate> uiDelegate;

@end

// see forwardingTargetForSelector: selector comment for the reason for this pragma
#pragma clang diagnostic ignored "-Wprotocol"

@implementation CDVWKWebViewEngine

@synthesize engineWebView = _engineWebView;

+ (NSString *)bundlePath
{
    return [[NSURL fileURLWithPath:[[NSBundle mainBundle] bundlePath]] path];
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super init];
    if (self) {
        if (NSClassFromString(@"WKWebView") == nil) {
            return nil;
        }
        fileQueue = [[NSOperationQueue alloc] init];
        urlSession = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
        self.uiDelegate = [[CDVWKWebViewUIDelegate alloc] initWithTitle:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"]];

        WKUserContentController* userContentController = [[WKUserContentController alloc] init];
        [userContentController addScriptMessageHandler:self name:CDV_BRIDGE_NAME];
        [userContentController addScriptMessageHandler:self name:CDV_IONIC_WK];
        [userContentController addUserScript:[self xhrPolyfillScript]];

        WKWebViewConfiguration* configuration = [[WKWebViewConfiguration alloc] init];
        configuration.userContentController = userContentController;

        WKWebView* wkWebView = [[WKWebView alloc] initWithFrame:frame configuration:configuration];
        wkWebView.UIDelegate = self.uiDelegate;

        self.engineWebView = wkWebView;

        NSLog(@"Using WKWebView");
    }

    return self;
}

- (void)pluginInitialize
{
    // viewController would be available now. we attempt to set all possible delegates to it, by default

    WKWebView* wkWebView = (WKWebView*)_engineWebView;

    if ([self.viewController conformsToProtocol:@protocol(WKUIDelegate)]) {
        wkWebView.UIDelegate = (id <WKUIDelegate>)self.viewController;
    }

    if ([self.viewController conformsToProtocol:@protocol(WKNavigationDelegate)]) {
        wkWebView.navigationDelegate = (id <WKNavigationDelegate>)self.viewController;
    } else {
        wkWebView.navigationDelegate = (id <WKNavigationDelegate>)self;
    }

    if ([self.viewController conformsToProtocol:@protocol(WKScriptMessageHandler)]) {
        [wkWebView.configuration.userContentController addScriptMessageHandler:(id < WKScriptMessageHandler >)self.viewController name:@"cordova"];
    }

    [self updateSettings:self.commandDelegate.settings];

    // check if content thread has died on resume
    NSLog(@"CDVWKWebViewEngine will reload WKWebView if required on resume");
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(onAppWillEnterForeground:)
               name:UIApplicationWillEnterForegroundNotification object:nil];
}

- (NSString *) stripBundleFromPath:(NSString *)src
{
    return [src substringFromIndex:[[CDVWKWebViewEngine bundlePath] length] + 1];
}

- (NSString *) runPath
{
    NSString* libPath = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject];
    return [libPath stringByAppendingPathComponent:@"NoCloud"];
}

- (void) cleanupAppFiles:(NSString *)location error:(NSError **)error
{
    NSFileManager *fileManager = [NSFileManager defaultManager];

    NSArray<NSString *>* entries = [fileManager contentsOfDirectoryAtPath:location error:error];
    if (*error) return;

    for (NSString* entry in entries) {
        if (![entry isEqualToString:STORAGEDIR]) {
            [fileManager removeItemAtPath:[location stringByAppendingPathComponent:entry] error:error];
            if (*error) break;
        }
    }
}

- (void)copyAppFiles:(NSError **)error
{
    NSString *dst = [self runPath];
    CDVViewController* vc = (CDVViewController*)self.viewController;

    NSString* srcPath = [[CDVWKWebViewEngine bundlePath] stringByAppendingPathComponent:vc.wwwFolderName];
    NSString* dstPath = [dst stringByAppendingPathComponent:vc.wwwFolderName];

    NSFileManager *fileManager = [NSFileManager defaultManager];

    if ([fileManager fileExistsAtPath:dstPath]) {
        [self cleanupAppFiles:dstPath error:error];
    } else {
        [fileManager createDirectoryAtPath:dstPath withIntermediateDirectories:false attributes:nil error:error];
        if (!*error) {
            NSString *storagePath = [dstPath stringByAppendingPathComponent:STORAGEDIR];
            [fileManager createDirectoryAtPath:storagePath withIntermediateDirectories:false attributes:nil error:error];
        }
    }

    if (*error) return;

    NSArray<NSString *>* entries = [fileManager contentsOfDirectoryAtPath:srcPath error:error];
    for (NSString *entry in entries) {
        [fileManager copyItemAtPath:[srcPath stringByAppendingPathComponent:entry] toPath:[dstPath stringByAppendingPathComponent:entry] error:error];
    }
}

- (void)requestStoragePath:(CDVInvokedUrlCommand*)command
{
    CDVViewController* vc = (CDVViewController*)self.viewController;
    NSString *runPath = [self runPath];
    NSString *storagePath = [[runPath stringByAppendingPathComponent:vc.wwwFolderName] stringByAppendingPathComponent:STORAGEDIR];

    CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:[[NSURL fileURLWithPath:storagePath] absoluteString]];

    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void) onAppWillEnterForeground:(NSNotification*)notification {
    [self reloadIfRequired];
}

- (BOOL)reloadIfRequired
{
    WKWebView* wkWebView = (WKWebView*)_engineWebView;
    NSString* title = wkWebView.title;
    BOOL reload = ((title == nil) || [title isEqualToString:@""]);

#ifdef DEBUG
    NSLog(@"CDVWKWebViewEngine reloadIfRequired");
    NSLog(@"CDVWKWebViewEngine reloadIfRequired WKWebView.title: %@", title);
    NSLog(@"CDVWKWebViewEngine reloadIfRequired reload: %u", reload);
#endif

    if (reload) {
        NSLog(@"CDVWKWebViewEngine reloading!");
        [wkWebView reload];
    }
    return reload;
}

- (id)loadRequest:(NSURLRequest*)request
{
    if ([self canLoadRequest:request]) { // can load, differentiate between file urls and other schemes
        if (request.URL.fileURL) {
            NSString* runPath = [self runPath];
            NSError *error = nil;

            [self copyAppFiles:&error];

            if (error) {
                NSString* errorHtml = [NSString stringWithFormat:
                                       @"<!doctype html>"
                                       @"<title>Error</title>"
                                       @"<div style='font-size:2em'>"
                                       @"   <p>The WebView engine '%@' is unable to load the request: %@</p>"
                                       @"   <p>Copy application files failed</p>"
                                       @"   <p>%@</p>"
                                       @"</div>",
                                       NSStringFromClass([self class]),
                                       [request.URL description],
                                       [error localizedDescription]
                                       ];
                return [self loadHTMLString:errorHtml baseURL:nil];

            } else {
                NSString* relativeLocation = [[request.URL path] substringFromIndex:[[CDVWKWebViewEngine bundlePath] length] + 1];
                NSURL* libApplicationUrl = [NSURL fileURLWithPath:[runPath stringByAppendingPathComponent:relativeLocation]];

                SEL wk_sel = NSSelectorFromString(CDV_WKWEBVIEW_FILE_URL_LOAD_SELECTOR);
                NSURL* readAccessUrl = [libApplicationUrl URLByDeletingLastPathComponent];
                return ((id (*)(id, SEL, id, id))objc_msgSend)(_engineWebView, wk_sel, libApplicationUrl, readAccessUrl);
            }
        } else {
            return [(WKWebView*)_engineWebView loadRequest:request];
        }
    } else { // can't load, print out error
        NSString* errorHtml = [NSString stringWithFormat:
                               @"<!doctype html>"
                               @"<title>Error</title>"
                               @"<div style='font-size:2em'>"
                               @"   <p>The WebView engine '%@' is unable to load the request: %@</p>"
                               @"   <p>Most likely the cause of the error is that the loading of file urls is not supported in iOS %@.</p>"
                               @"</div>",
                               NSStringFromClass([self class]),
                               [request.URL description],
                               [[UIDevice currentDevice] systemVersion]
                               ];
        return [self loadHTMLString:errorHtml baseURL:nil];
    }
}

- (id)loadHTMLString:(NSString*)string baseURL:(NSURL*)baseURL
{
    return [(WKWebView*)_engineWebView loadHTMLString:string baseURL:baseURL];
}

- (NSURL*) URL
{
    return [(WKWebView*)_engineWebView URL];
}

- (BOOL) canLoadRequest:(NSURLRequest*)request
{
    // See: https://issues.apache.org/jira/browse/CB-9636
    SEL wk_sel = NSSelectorFromString(CDV_WKWEBVIEW_FILE_URL_LOAD_SELECTOR);

    // if it's a file URL, check whether WKWebView has the selector (which is in iOS 9 and up only)
    if (request.URL.fileURL) {
        return [_engineWebView respondsToSelector:wk_sel];
    } else {
        return YES;
    }
}

- (void)updateSettings:(NSDictionary*)settings
{
    WKWebView* wkWebView = (WKWebView*)_engineWebView;

    wkWebView.configuration.preferences.minimumFontSize = [settings cordovaFloatSettingForKey:@"MinimumFontSize" defaultValue:0.0];
    wkWebView.configuration.allowsInlineMediaPlayback = [settings cordovaBoolSettingForKey:@"AllowInlineMediaPlayback" defaultValue:NO];
    wkWebView.configuration.mediaPlaybackRequiresUserAction = [settings cordovaBoolSettingForKey:@"MediaPlaybackRequiresUserAction" defaultValue:YES];
    wkWebView.configuration.suppressesIncrementalRendering = [settings cordovaBoolSettingForKey:@"SuppressesIncrementalRendering" defaultValue:NO];
    wkWebView.configuration.mediaPlaybackAllowsAirPlay = [settings cordovaBoolSettingForKey:@"MediaPlaybackAllowsAirPlay" defaultValue:YES];


    // By default, DisallowOverscroll is false (thus bounce is allowed)
    BOOL bounceAllowed = !([settings cordovaBoolSettingForKey:@"DisallowOverscroll" defaultValue:NO]);

    // prevent webView from bouncing
    if (!bounceAllowed) {
        if ([wkWebView respondsToSelector:@selector(scrollView)]) {
            ((UIScrollView*)[wkWebView scrollView]).bounces = NO;
        } else {
            for (id subview in wkWebView.subviews) {
                if ([[subview class] isSubclassOfClass:[UIScrollView class]]) {
                    ((UIScrollView*)subview).bounces = NO;
                }
            }
        }
    }

    wkWebView.scrollView.scrollEnabled = [settings cordovaFloatSettingForKey:@"ScrollEnabled" defaultValue:YES];

    NSString* decelerationSetting = [settings cordovaSettingForKey:@"WKWebViewDecelerationSpeed"];
    if (!decelerationSetting) {
        // Fallback to the UIWebView-named preference
        decelerationSetting = [settings cordovaSettingForKey:@"UIWebViewDecelerationSpeed"];
    }

    if (![@"fast" isEqualToString:decelerationSetting]) {
        [wkWebView.scrollView setDecelerationRate:UIScrollViewDecelerationRateNormal];
    } else {
        [wkWebView.scrollView setDecelerationRate:UIScrollViewDecelerationRateFast];
    }
}

- (void)updateWithInfo:(NSDictionary*)info
{
    NSDictionary* scriptMessageHandlers = [info objectForKey:kCDVWebViewEngineScriptMessageHandlers];
    NSDictionary* settings = [info objectForKey:kCDVWebViewEngineWebViewPreferences];
    id navigationDelegate = [info objectForKey:kCDVWebViewEngineWKNavigationDelegate];
    id uiDelegate = [info objectForKey:kCDVWebViewEngineWKUIDelegate];

    WKWebView* wkWebView = (WKWebView*)_engineWebView;

    if (scriptMessageHandlers && [scriptMessageHandlers isKindOfClass:[NSDictionary class]]) {
        NSArray* allKeys = [scriptMessageHandlers allKeys];

        for (NSString* key in allKeys) {
            id object = [scriptMessageHandlers objectForKey:key];
            if ([object conformsToProtocol:@protocol(WKScriptMessageHandler)]) {
                [wkWebView.configuration.userContentController addScriptMessageHandler:object name:key];
            }
        }
    }

    if (navigationDelegate && [navigationDelegate conformsToProtocol:@protocol(WKNavigationDelegate)]) {
        wkWebView.navigationDelegate = navigationDelegate;
    }

    if (uiDelegate && [uiDelegate conformsToProtocol:@protocol(WKUIDelegate)]) {
        wkWebView.UIDelegate = uiDelegate;
    }

    if (settings && [settings isKindOfClass:[NSDictionary class]]) {
        [self updateSettings:settings];
    }
}

// This forwards the methods that are in the header that are not implemented here.
// Both WKWebView and UIWebView implement the below:
//     loadHTMLString:baseURL:
//     loadRequest:
- (id)forwardingTargetForSelector:(SEL)aSelector
{
    return _engineWebView;
}

- (UIView*)webView
{
    return self.engineWebView;
}

- (WKUserScript*)xhrPolyfillScript
{
    NSString *scriptFile = [[NSBundle mainBundle] pathForResource:@"www/xhr" ofType:@"js"];
    if (scriptFile == nil) {
        NSLog(@"XHR polyfill was not found!");
        return nil;
    }
    NSString *source = [NSString stringWithContentsOfFile:scriptFile encoding:NSUTF8StringEncoding error:nil];
    return [[WKUserScript alloc] initWithSource:source
                                  injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                               forMainFrameOnly:NO];
}

#pragma mark WKScriptMessageHandler implementation

- (void)userContentController:(WKUserContentController*)userContentController didReceiveScriptMessage:(WKScriptMessage*)message
{
    if ([message.name isEqualToString:CDV_BRIDGE_NAME]) {
        [self handleCordovaMessage: message];
    } else if ([message.name isEqualToString:CDV_IONIC_WK]) {
        [self handleXHRMessage: message];
    }
}

- (void)handleCordovaMessage:(WKScriptMessage*)message
{
    CDVViewController* vc = (CDVViewController*)self.viewController;

    NSArray* jsonEntry = message.body; // NSString:callbackId, NSString:service, NSString:action, NSArray:args
    CDVInvokedUrlCommand* command = [CDVInvokedUrlCommand commandFromJson:jsonEntry];
    CDV_EXEC_LOG(@"Exec(%@): Calling %@.%@", command.callbackId, command.className, command.methodName);

    if (![vc.commandQueue execute:command]) {
#ifdef DEBUG
        NSError* error = nil;
        NSString* commandJson = nil;
        NSData* jsonData = [NSJSONSerialization dataWithJSONObject:jsonEntry
                                                           options:0
                                                             error:&error];

        if (error == nil) {
            commandJson = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        }

        static NSUInteger maxLogLength = 1024;
        NSString* commandString = ([commandJson length] > maxLogLength) ?
        [NSString stringWithFormat : @"%@[...]", [commandJson substringToIndex:maxLogLength]] :
        commandJson;

        NSLog(@"FAILED pluginJSON = %@", commandString);
#endif
    }
}

- (void)handleXHRMessage:(WKScriptMessage *)message
{
    NSString *str = message.body;
    if (!str || ![str isKindOfClass:[NSString class]] || [str length] < 4) {
        NSLog(@"Invalid XHR request");
        return;
    }
    NSData *data = [message.body dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    NSDictionary *request = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (!request || error != nil) {
        NSLog(@"JSON response could not be parsed");
        return;
    }

	NSNumber *reqID = request[@"id"];
    if(!reqID || ![reqID isKindOfClass:[NSNumber class]]) {
        NSLog(@"XHR's ID is invalid'");
        return;
    }
	NSString *url = request[@"url"];
    if(!url || ![url isKindOfClass:[NSString class]]) {
        NSLog(@"XHR's URL is invalid'");
        return;
    }

    NSString *method = request[@"method"];
    if(!method || ![method isKindOfClass:[NSString class]]) {
        NSLog(@"XHR's method is invalid'");
        return;
    }

    NSObject *postData = request[@"data"];
    if(!postData) {
        NSLog(@"XHR's data is invalid'");
        return;
    }

    NSDictionary *headers = request[@"headers"];
    if(!headers || ![headers isKindOfClass:[NSDictionary class]]) {
        NSLog(@"XHR's headers are invalid'");
        return;
    }

    if ([self isRelativeUrl:url]) {
        WKWebView* wkWebView = (WKWebView*)_engineWebView;
        NSURL *fileURL = [[[wkWebView URL] URLByDeletingLastPathComponent] URLByAppendingPathComponent:url];
        [self loadFile:reqID fileURL:fileURL];
    } else if ([[NSURL URLWithString:url] isFileURL]) {
        [self loadFile:reqID fileURL:[NSURL URLWithString:url]];
    } else if ([postData isKindOfClass:[NSString class]]) {
        NSString *bodyStr = (NSString *)postData;
        NSData *bodyData = [bodyStr dataUsingEncoding:NSUTF8StringEncoding];

        [self sendHttpRequest:reqID method:method url:url httpBody:bodyData headers:headers];
    } else if ([postData isKindOfClass:[NSDictionary class]]) {
        NSString* const boundary = @"+++++wkwebview.formBoundary";
        NSString* contentType = [NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary];
        NSData* boundaryData = [[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding];
        NSData* closingChunk = [[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding];

        NSDictionary *formData = (NSDictionary *)postData;

        static const NSUInteger kStreamBufferSize = 32768;
        NSArray *dataChunks = [self buildMultipartPostDataFrom:formData[@"data"] withBoundary:boundaryData];
        NSArray *fileChunks = [self buildMultipartPostFileDataFrom:formData[@"files"] withBoundary:boundaryData];
        NSArray *chunks = [[dataChunks arrayByAddingObjectsFromArray:fileChunks] arrayByAddingObject:closingChunk];

        NSInteger numChunks = [chunks count];

        long contentLength = 0;
        for (int i = 0; i < numChunks; ++i) {
            contentLength += [chunks[i] length];
        }

        NSMutableDictionary *mutableHeaders = [headers mutableCopy];
        [mutableHeaders setValue:contentType forKey:@"Content-Type" ];
        [mutableHeaders setValue:[NSString stringWithFormat:@"%ld", (long)contentLength] forKey:@"Content-Length"];

        CFReadStreamRef readStream = NULL;
        CFWriteStreamRef writeStream = NULL;
        CFStreamCreateBoundPair(NULL, &readStream, &writeStream, kStreamBufferSize);
        NSInputStream* bodyStream = CFBridgingRelease(readStream);

        [self.commandDelegate runInBackground:^{
            if (CFWriteStreamOpen(writeStream)) {
                for (int i = 0; i < numChunks; ++i) {
                    CFIndex result = [self writeDataToStream:chunks[i] stream:writeStream];
                    if (result <= 0) {
                        break;
                    }
                }
            }

            CFWriteStreamClose(writeStream);
            CFRelease(writeStream);
        }];

        [self sendHttpRequest:reqID method:method url:url httpBodyStream:bodyStream headers:mutableHeaders];
    }
}

- (NSArray *) buildMultipartPostDataFrom:(NSArray *)formData withBoundary:(NSData *)boundary
{
    NSMutableArray *chunks = [[NSMutableArray alloc] init];

    [formData enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        NSDictionary *entry = obj;

        NSString *name = entry[@"name"];
        id value = entry[@"value"];
        if ([value respondsToSelector:@selector(stringValue)]) {
            value = [value stringValue];
        }

        [chunks addObject:boundary];
        [chunks addObject:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"\r\n\r\n", name]
                           dataUsingEncoding:NSUTF8StringEncoding]];
        [chunks addObject:[value dataUsingEncoding:NSUTF8StringEncoding]];
        [chunks addObject:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    }];

  return chunks;
}

- (NSArray *) buildMultipartPostFileDataFrom:(NSArray *)formData withBoundary:(NSData *)boundary
{
    NSMutableArray *chunks = [[NSMutableArray alloc] init];

    [formData enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        NSDictionary *entry = obj;
        NSString *name = entry[@"name"];
        NSString *fileName = entry[@"fileName"];

        NSString *filePath = [[NSURL URLWithString:entry[@"fileUrl"]] path];
        NSData* fileData = [NSData dataWithContentsOfFile:filePath options:NSDataReadingMappedIfSafe error:nil];

        [chunks addObject:boundary];
        [chunks addObject:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"; filename=\"%@\"\r\n", name, fileName]
                           dataUsingEncoding:NSUTF8StringEncoding]];
        [chunks addObject:[@"Content-Type: application/octet-stream\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [chunks addObject:[[NSString stringWithFormat:@"Content-Length: %ld\r\n\r\n", (long)[fileData length]] dataUsingEncoding:NSUTF8StringEncoding]];
        [chunks addObject:fileData];
        [chunks addObject:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    }];

    return chunks;
}

-(CFIndex) writeDataToStream:(NSData*) data stream:(CFWriteStreamRef)stream
{
    UInt8* bytes = (UInt8*)[data bytes];
    long long bytesToWrite = [data length];
    long long totalBytesWritten = 0;

    while (totalBytesWritten < bytesToWrite) {
        CFIndex result = CFWriteStreamWrite(stream, bytes + totalBytesWritten, bytesToWrite - totalBytesWritten);
        if (result < 0) {
            CFStreamError error = CFWriteStreamGetError(stream);
            NSLog(@"WriteStreamError domain: %ld error: %ld", error.domain, (long)error.error);
            return result;
        } else if (result == 0) {
            return result;
        }
        totalBytesWritten += result;
    }

    return totalBytesWritten;
}

- (BOOL)isRelativeUrl:(NSString *)url
{
    NSError *error = nil;
    NSRegularExpression *protocolRegex = [NSRegularExpression regularExpressionWithPattern:@"^[a-zA-Z0-9]+://"
      options:0 error:&error];

    NSUInteger numberOfMatches = [protocolRegex numberOfMatchesInString:url options:0
      range:NSMakeRange(0, [url length])];

    return numberOfMatches == 0;
}

-(void)loadFile:(NSNumber *)requestId fileURL:(NSURL *)requestURL
{
    [fileQueue addOperationWithBlock:^{
        NSError *error = nil;
        NSString *source = [NSString stringWithContentsOfURL:requestURL encoding:NSUTF8StringEncoding error:&error];

        if (error) {
            [self sendXHRResponse:requestId statusCode:0 response:@""];
        } else {
            [self sendXHRResponse:requestId statusCode:200 response:source];
        }
    }];
}

- (void)sendHttpRequest:(NSNumber *)requestId method:(NSString *)requestMethod url:(NSString *)url httpBody:(NSData*)bodyData headers:(NSDictionary *)headers
{
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    request.HTTPBody = bodyData;

    [self sendHttpRequest:request requestId:requestId method:requestMethod headers:headers];
}

- (void)sendHttpRequest:(NSNumber *)requestId method:(NSString *)requestMethod url:(NSString *)url httpBodyStream:(NSInputStream*)bodyData headers:(NSDictionary *)headers
{
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    request.HTTPBodyStream = bodyData;

    [self sendHttpRequest:request requestId:requestId method:requestMethod headers:headers];
}


- (void)sendHttpRequest:(NSMutableURLRequest*)request requestId:(NSNumber *)requestId method:(NSString *)requestMethod headers:(NSDictionary *)headers
{
    request.HTTPMethod = requestMethod;

    for (id key in headers) {
        [request setValue:[headers valueForKey:key] forHTTPHeaderField:key];
    }

    NSURLSessionDataTask* dataTask = [urlSession dataTaskWithRequest:request completionHandler:^(NSData *data,
                                                        NSURLResponse *response,
                                                        NSError *error){

        NSInteger statusCode = 0;
        NSString *responseText = @"";

        if (!error) {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            statusCode = [httpResponse statusCode];
            responseText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        }

        [self sendXHRResponse:requestId statusCode:statusCode response:responseText];
    }];

    [dataTask resume];
}

- (void)sendXHRResponse:(NSNumber *)requestId statusCode:(NSInteger)status response:(NSString *)responseText
{
    NSString *jsCode = [NSString stringWithFormat:@"handleXHRResponse(%@, %ld, %@)",
                        [requestId stringValue], (long)status, [self quoteString: responseText]];

    WKWebView* wkWebView = (WKWebView*)_engineWebView;

    dispatch_async(dispatch_get_main_queue(), ^{
        [wkWebView evaluateJavaScript:jsCode completionHandler:nil];
    });
}

- (NSString *)quoteString:(NSString *)str
{
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[str] options:0 error:&error];
    if (!data || error != nil) {
        NSLog(@"String escaping failed: JSON generation");
        return nil;
    }
    NSString *jsonString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if(!jsonString || [jsonString length] < 4) {
        NSLog(@"String escaping failed: JSON result");
        return nil;
    }
    return [jsonString substringWithRange: NSMakeRange(1, jsonString.length-2)];
}


#pragma mark WKNavigationDelegate implementation

- (void)webView:(WKWebView*)webView didStartProvisionalNavigation:(WKNavigation*)navigation
{
    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:CDVPluginResetNotification object:webView]];
}

- (void)webView:(WKWebView*)webView didFinishNavigation:(WKNavigation*)navigation
{
    CDVViewController* vc = (CDVViewController*)self.viewController;
    [CDVUserAgentUtil releaseLock:vc.userAgentLockToken];

    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:CDVPageDidLoadNotification object:webView]];
}

- (void)webView:(WKWebView*)theWebView didFailNavigation:(WKNavigation*)navigation withError:(NSError*)error
{
    CDVViewController* vc = (CDVViewController*)self.viewController;
    [CDVUserAgentUtil releaseLock:vc.userAgentLockToken];

    NSString* message = [NSString stringWithFormat:@"Failed to load webpage with error: %@", [error localizedDescription]];
    NSLog(@"%@", message);

    NSURL* errorUrl = vc.errorURL;
    if (errorUrl) {
        errorUrl = [NSURL URLWithString:[NSString stringWithFormat:@"?error=%@", [message stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]] relativeToURL:errorUrl];
        NSLog(@"%@", [errorUrl absoluteString]);
        [theWebView loadRequest:[NSURLRequest requestWithURL:errorUrl]];
    }
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView
{
    [webView reload];
}

- (BOOL)defaultResourcePolicyForURL:(NSURL*)url
{
    // all file:// urls are allowed
    if ([url isFileURL]) {
        return YES;
    }

    return NO;
}

- (void) webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction*)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    NSURL* url = [navigationAction.request URL];
    CDVViewController* vc = (CDVViewController*)self.viewController;

    /*
     * Give plugins the chance to handle the url
     */
    BOOL anyPluginsResponded = NO;
    BOOL shouldAllowRequest = NO;

    for (NSString* pluginName in vc.pluginObjects) {
        CDVPlugin* plugin = [vc.pluginObjects objectForKey:pluginName];
        SEL selector = NSSelectorFromString(@"shouldOverrideLoadWithRequest:navigationType:");
        if ([plugin respondsToSelector:selector]) {
            anyPluginsResponded = YES;
            shouldAllowRequest = (((BOOL (*)(id, SEL, id, int))objc_msgSend)(plugin, selector, navigationAction.request, navigationAction.navigationType));
            if (!shouldAllowRequest) {
                break;
            }
        }
    }

    if (anyPluginsResponded) {
        return decisionHandler(shouldAllowRequest);
    }

    /*
     * Handle all other types of urls (tel:, sms:), and requests to load a url in the main webview.
     */
    BOOL shouldAllowNavigation = [self defaultResourcePolicyForURL:url];
    if (shouldAllowNavigation) {
        return decisionHandler(YES);
    } else {
        [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:CDVPluginHandleOpenURLNotification object:url]];
    }

    return decisionHandler(NO);
}
@end
