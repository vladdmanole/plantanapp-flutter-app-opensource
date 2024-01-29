import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:barcode_scan2/barcode_scan2.dart';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:root/root.dart';
import 'package:ssl_pinning_plugin/ssl_pinning_plugin.dart';

import 'location_request_type.dart';
import 'precision.dart';

const appUrlStr = String.fromEnvironment('PAA_APP_URL', defaultValue: '');
const String appCertificateStr =
    String.fromEnvironment('PAA_APP_CERTIFICATE', defaultValue: '');
const String appCertificateSecondStr =
    String.fromEnvironment('PAA_APP_CERTIFICATE_SECOND', defaultValue: '');

final Uri appUrl = Uri.parse(appUrlStr);
// needed for debugging - should be commented
// final Uri appUrl = Uri.parse('https://idtag.apps.plantanapp.com/Barcode-Testing');

Future main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isAndroid) {
    await AndroidInAppWebViewController.setWebContentsDebuggingEnabled(true);
  }

  runApp(
    const MaterialApp(
      home: WebViewApp(),
    ),
  );
}

class WebViewApp extends StatefulWidget {
  const WebViewApp({super.key});

  @override
  State<WebViewApp> createState() => _WebViewAppState();
}

class _WebViewAppState extends State<WebViewApp> with TickerProviderStateMixin {
  final GlobalKey globalKey = GlobalKey();

  InAppWebViewController? webViewController;
  InAppWebViewGroupOptions options = InAppWebViewGroupOptions(
      crossPlatform: InAppWebViewOptions(
          useShouldOverrideUrlLoading: true,
          mediaPlaybackRequiresUserGesture: false,
          supportZoom: false),
      android: AndroidInAppWebViewOptions(
        useHybridComposition: true,
      ),
      ios: IOSInAppWebViewOptions(
        allowsInlineMediaPlayback: true,
      ));

  late PullToRefreshController pullToRefreshController;
  double progress = 0;
  String url = "";
  final urlController = TextEditingController();

  bool _rootStatus = false;
  bool _sslCheckCompleted = false;
  bool _sslStatus = false;

  @override
  void initState() {
    super.initState();
    checkRoot();
    checkSSL().then((sslStatus) {
      setState(() {
        _sslCheckCompleted = true;
        _sslStatus = sslStatus;
      });
    });

    pullToRefreshController = PullToRefreshController(
      options: PullToRefreshOptions(
        color: Colors.blue,
      ),
      onRefresh: () async {
        if (Platform.isAndroid) {
          webViewController?.reload();
        } else if (Platform.isIOS) {
          webViewController?.loadUrl(
              urlRequest: URLRequest(url: await webViewController?.getUrl()));
        }
      },
    );
  }

  //Check Root status
  Future<void> checkRoot() async {
    bool? result = await Root.isRooted();
    setState(() {
      _rootStatus = result!;
    });
  }

  // SSL pinning
  Future<bool> checkSSL() async {
    try {
      bool checked = false;
      List<String> allowedShA1FingerprintList = [
        appCertificateStr,
        appCertificateSecondStr
      ];
      String _status = await SslPinningPlugin.check(
        serverURL: appUrl.toString(),
        headerHttp: new Map(),
        httpMethod: HttpMethod.Get,
        sha: SHA.SHA256,
        allowedSHAFingerprints: allowedShA1FingerprintList,
        timeout: 100,
      );
      if (_status == "CONNECTION_SECURE") {
        checked = true;
      }
      return checked;
    } catch (error) {
      print('SSL Pinning Error | $error');
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
        onWillPop: () async {
          if (!_sslCheckCompleted) {
            // Prevent navigating back when SSL check is not completed
            return Future.value(false);
          }

          if (webViewController != null) {
            if (await webViewController!.canGoBack()) {
              webViewController!.goBack();
              return Future.value(false);
            }
          }
          return Future.value(true);
        },
        child: !_sslCheckCompleted
            ? Center(
                child:
                    CircularProgressIndicator()) // show loading spinner when SSL check is not completed
            : (_rootStatus
                ? const Scaffold(
                    body: Center(
                        child: Text(
                            "Your device is rooted! You can't use this app. (Error: Device is Rooted)",
                            style: TextStyle(fontWeight: FontWeight.bold))),
                  )
                : (!_sslStatus
                    ? const Scaffold(
                        body: Center(
                            child: Text(
                                "The website's certificate is not known. Please download the latest version of the app. (Error: SSL Pinning Failed)",
                                style: TextStyle(fontWeight: FontWeight.bold))),
                      )
                    : Scaffold(
                        // appBar: AppBar(title: const Text("Official InAppWebView website")),
                        key: globalKey,
                        body: SafeArea(
                            child: Column(children: <Widget>[
                          Expanded(
                            child: Stack(
                              children: [
                                InAppWebView(
                                  initialUrlRequest: URLRequest(url: appUrl),
                                  initialOptions: options,
                                  pullToRefreshController:
                                      pullToRefreshController,
                                  onWebViewCreated: (controller) async {
                                    webViewController = controller;

                                    await controller.addWebMessageListener(
                                        WebMessageListener(
                                      jsObjectName: "PaaFlutterSnackbar",
                                      onPostMessage: (message, sourceOrigin,
                                          isMainFrame, replyProxy) async {
                                        if (message == null) {
                                          return;
                                        }

                                        final parsedMessage =
                                            json.decode(message);
                                        String snack = parsedMessage['message'];
                                        ScaffoldMessenger.of(
                                                globalKey.currentContext!)
                                            .showSnackBar(
                                          SnackBar(content: Text(snack)),
                                        );
                                      },
                                    ));

                                    await controller.addWebMessageListener(
                                        WebMessageListener(
                                      jsObjectName: "PaaScan",
                                      allowedOriginRules: {
                                        "https://*.plantanapp.com"
                                      },
                                      onPostMessage: (message, sourceOrigin,
                                          isMainFrame, replyProxy) async {
                                        if (message == 'paa.scan') {
                                          ScanResult scanResult =
                                              await BarcodeScanner.scan();
                                          String code = scanResult.rawContent;
                                          replyProxy.postMessage(code);
                                        }
                                      },
                                    ));

                                    await controller.addWebMessageListener(
                                        WebMessageListener(
                                      jsObjectName: "PaaLocation",
                                      onPostMessage: (message, sourceOrigin,
                                          isMainFrame, replyProxy) async {
                                        if (message == null) {
                                          return;
                                        }

                                        final parsedMessage =
                                            json.decode(message);

                                        LocationAccuracy accuracy;
                                        switch (parsedMessage['precision']) {
                                          case Precision.lowest:
                                            accuracy = LocationAccuracy.lowest;
                                            break;
                                          case Precision.low:
                                            accuracy = LocationAccuracy.low;
                                            break;
                                          case Precision.medium:
                                            accuracy = LocationAccuracy.medium;
                                            break;
                                          case Precision.high:
                                            accuracy = LocationAccuracy.high;
                                            break;
                                          case Precision.best:
                                            accuracy = LocationAccuracy.best;
                                            break;
                                          case Precision.bestForNavigation:
                                            accuracy = LocationAccuracy
                                                .bestForNavigation;
                                            break;
                                          default:
                                            accuracy = LocationAccuracy.high;
                                            break;
                                        }

                                        switch (parsedMessage[
                                            'locationRequestType']) {
                                          case LocationRequestType.address:
                                            // Request location permission
                                            final permission = await Geolocator
                                                .requestPermission();
                                            if (permission ==
                                                LocationPermission.denied) {
                                              replyProxy.postMessage(
                                                  'Location permission denied');
                                              return;
                                            }

                                            // Get current position
                                            Position position = await Geolocator
                                                .getCurrentPosition(
                                              desiredAccuracy: accuracy,
                                            );
                                            List<Placemark> placemarks =
                                                await placemarkFromCoordinates(
                                              position.latitude,
                                              position.longitude,
                                            );
                                            Placemark placemark =
                                                placemarks.first;
                                            replyProxy.postMessage(
                                                placemark.name ??
                                                    'Unknown location');
                                            break;

                                          case LocationRequestType.coordinates:
                                            // Request location permission
                                            final permission = await Geolocator
                                                .requestPermission();
                                            if (permission ==
                                                LocationPermission.denied) {
                                              replyProxy.postMessage(
                                                  'Location permission denied');
                                              return;
                                            }

                                            // Get current position
                                            Position position = await Geolocator
                                                .getCurrentPosition(
                                              desiredAccuracy: accuracy,
                                            );
                                            replyProxy.postMessage(json.encode({
                                              'lat': position.latitude,
                                              'long': position.longitude,
                                            }));
                                            break;

                                          case LocationRequestType
                                                .addressFromCoordinates:
                                            List<Placemark> placemarks =
                                                await placemarkFromCoordinates(
                                              parsedMessage['latitude'],
                                              parsedMessage['longitude'],
                                            );
                                            Placemark placemark =
                                                placemarks.first;
                                            replyProxy.postMessage(
                                                placemark.name ??
                                                    'Unknown location');
                                            break;

                                          case LocationRequestType
                                                .coordinatesFromAddress:
                                            List<Location> locations =
                                                await locationFromAddress(
                                              parsedMessage['locationName'],
                                            );
                                            Location location = locations.first;
                                            replyProxy.postMessage(json.encode({
                                              'latitude': location.latitude,
                                              'longitude': location.longitude,
                                            }));
                                            break;
                                        }
                                      },
                                    ));
                                  },
                                  onLoadStart: (controller, url) {
                                    setState(() {
                                      this.url = url.toString();
                                      urlController.text = this.url;
                                    });
                                  },
                                  androidOnPermissionRequest:
                                      (controller, origin, resources) async {
                                    return PermissionRequestResponse(
                                        resources: resources,
                                        action: PermissionRequestResponseAction
                                            .GRANT);
                                  },
                                  onReceivedServerTrustAuthRequest:
                                      (controller, challenge) async {
                                    print(challenge);
                                    return ServerTrustAuthResponse(
                                        action: ServerTrustAuthResponseAction
                                            .PROCEED);
                                  },
                                  shouldOverrideUrlLoading:
                                      (controller, navigationAction) async {
                                    var uri = navigationAction.request.url!;

                                    if (![
                                      "http",
                                      "https",
                                      "file",
                                      "chrome",
                                      "data",
                                      "javascript",
                                      "about"
                                    ].contains(uri.scheme)) {
                                      if (await canLaunchUrl(appUrl)) {
                                        // Launch the App
                                        await launchUrl(
                                          appUrl,
                                        );
                                        // and cancel the request
                                        return NavigationActionPolicy.CANCEL;
                                      }
                                    }

                                    return NavigationActionPolicy.ALLOW;
                                  },
                                  onLoadStop: (controller, url) async {
                                    pullToRefreshController.endRefreshing();
                                    setState(() {
                                      this.url = url.toString();
                                      urlController.text = this.url;
                                    });
                                  },
                                  onLoadError:
                                      (controller, url, code, message) {
                                    pullToRefreshController.endRefreshing();
                                  },
                                  onProgressChanged: (controller, progress) {
                                    if (progress == 100) {
                                      pullToRefreshController.endRefreshing();
                                    }
                                    setState(() {
                                      this.progress = progress / 100;
                                      urlController.text = url;
                                    });
                                  },
                                  onUpdateVisitedHistory:
                                      (controller, url, androidIsReload) {
                                    setState(() {
                                      this.url = url.toString();
                                      urlController.text = this.url;
                                    });
                                  },
                                  onConsoleMessage:
                                      (controller, consoleMessage) {
                                    debugPrint(consoleMessage.toString());
                                  },
                                ),
                                progress < 1.0
                                    ? LinearProgressIndicator(value: progress)
                                    : Container(),
                              ],
                            ),
                          ),
                        ]))))));
  }
}
