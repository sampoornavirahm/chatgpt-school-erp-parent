import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:school_erp_mobile_shared/src/api_client.dart';
import 'package:school_erp_mobile_shared/src/calendar_event_presentation.dart';
import 'package:school_erp_mobile_shared/src/firebase_services.dart';
import 'package:school_erp_mobile_shared/src/meeting_link.dart';
import 'package:school_erp_mobile_shared/src/parent_biometric_service.dart';
import 'package:school_erp_mobile_shared/src/offline_sync_store.dart';
import 'package:school_erp_mobile_shared/src/parent_request_dates.dart';
import 'package:school_erp_mobile_shared/src/offline_sync_service.dart';
import 'package:school_erp_mobile_shared/src/timetable_projection.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

enum MobileRole { teacher, parent }

const _uatDistributionEnabled = bool.fromEnvironment('SCHOOL_ERP_UAT');
const _appDistributionChannel = MethodChannel('school_erp/app_distribution');

Future<void> launchSchoolErpApp({
  required MobileRole role,
  required FirebaseOptions firebaseOptions,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(SchoolErpMobile(role: role));
  unawaited(_initializeOptionalFirebase(firebaseOptions));
}

Future<void> _initializeOptionalFirebase(FirebaseOptions options) async {
  try {
    final firebaseReady = await FirebaseServices.initialize(options);
    if (!firebaseReady) return;

    FirebaseMessaging.onBackgroundMessage(schoolErpFcmBackgroundHandler);
    final preferences = await SharedPreferences.getInstance();
    await FirebaseServices.setAnalyticsConsent(
      preferences.getBool('school_erp_analytics_consent') ?? false,
    );
    if (_uatDistributionEnabled && Platform.isAndroid) {
      unawaited(_checkUatDistributionUpdate());
    }
  } catch (_) {
    // Firebase services are optional; they must not block app startup.
  }
}

Future<void> _checkUatDistributionUpdate() async {
  if (!_uatDistributionEnabled ||
      !Platform.isAndroid ||
      !FirebaseServices.ready)
    return;
  try {
    await _appDistributionChannel.invokeMethod<void>('checkForUpdate');
  } on PlatformException {
    // Keep normal app use available if the tester service is temporarily unavailable.
  } on MissingPluginException {
    // Firebase App Distribution is only included in UAT Android builds.
  }
}

@pragma('vm:entry-point')
Future<void> schoolErpFcmBackgroundHandler(RemoteMessage message) async {
  // FCM payloads carry only a generic event; fetch school details after sign-in.
  if (Firebase.apps.isEmpty) await Firebase.initializeApp();
}

extension on MobileRole {
  String get apiValue => this == MobileRole.teacher ? 'teacher' : 'parent';
  String get title => this == MobileRole.teacher ? 'Teacher' : 'Parent';
  String get welcome =>
      this == MobileRole.teacher
          ? 'Your teaching day, at a glance.'
          : 'Your child’s school day, at a glance.';
  List<String> get areas =>
      this == MobileRole.teacher
          ? ['My classes', 'Attendance', 'School messages']
          : ['My child', 'Attendance', 'School messages'];
}

class SchoolErpMobile extends StatefulWidget {
  const SchoolErpMobile({super.key, required this.role});

  final MobileRole role;

  @override
  State<SchoolErpMobile> createState() => _SchoolErpMobileState();
}

class _SchoolErpMobileState extends State<SchoolErpMobile>
    with WidgetsBindingObserver {
  static const _apiUrlKey = 'school_erp_api_url';
  static const _hubModeKey = 'school_erp_local_hub_mode';
  static const _hubSchoolIdKey = 'school_erp_hub_school_id';
  static const _parentBiometricKey = 'school_erp_parent_biometric_unlock';
  static const _parentTextScaleKey = 'school_erp_parent_text_scale';
  static const _parentNotificationPreferencePrefix =
      'school_erp_parent_notification_preferences_';
  static const _defaultParentNotificationPreferences = <String, bool>{
    'school_notice': true,
    'schedule_update': true,
    'homework_update': true,
  };
  static bool _googleSignInInitialized = false;
  final _api = ApiClient();
  StreamSubscription<RemoteMessage>? _messageSubscription;
  StreamSubscription<RemoteMessage>? _messageOpenedSubscription;
  StreamSubscription<String>? _tokenSubscription;
  bool _initialMessageChecked = false;
  int _notificationRevision = 0;
  String? _notificationType;
  bool _notificationOpened = false;
  bool _loading = true;
  bool _working = false;
  bool _signedIn = false;
  bool _hubMode = false;
  bool _offline = false;
  bool _legacyCacheMatchesAccount = false;
  bool _setupJustCompleted = false;
  bool _analyticsConsent = false;
  bool _biometricEnabled = false;
  double _parentTextScale = 1.0;
  bool _biometricLocked = false;
  bool _updatePromptShown = false;
  bool _updateCheckRunning = false;
  String? _dismissedUpdateKey;
  String? _error;
  String? _success;
  String? _googleIdToken;
  String? _googleEmail;
  Map<String, dynamic>? _setupStatus;
  Map<String, dynamic>? _user;
  String? _schoolId;
  List<Map<String, dynamic>> _parentChildren = [];
  List<Map<String, dynamic>> _parentCommands = [];
  List<Map<String, dynamic>> _parentSupportTickets = [];
  bool _parentSupportAvailable = true;
  bool _parentCacheCleared = false;
  String? _pendingSupportFingerprint;
  String? _pendingSupportOperationId;
  String? _pendingPublicSupportFingerprint;
  String? _pendingPublicSupportOperationId;
  Map<String, bool> _parentNotificationPreferences = {
    ..._defaultParentNotificationPreferences,
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_bootstrap());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_checkForAppUpdate());
      unawaited(_checkUatDistributionUpdate());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messageSubscription?.cancel();
    _messageOpenedSubscription?.cancel();
    _tokenSubscription?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap({bool skipBiometric = false}) async {
    try {
      await _bootstrapState(skipBiometric: skipBiometric);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error =
              'Could not finish startup. Check your connection and try again.';
          _loading = false;
        });
      }
    }
  }

  Future<void> _bootstrapState({bool skipBiometric = false}) async {
    final preferences = await SharedPreferences.getInstance();
    final savedUrl = preferences.getString(_apiUrlKey);
    _hubMode = preferences.getBool(_hubModeKey) ?? false;
    _schoolId = preferences.getString(_hubSchoolIdKey);
    _analyticsConsent =
        preferences.getBool('school_erp_analytics_consent') ?? false;
    _parentTextScale =
        widget.role == MobileRole.parent
            ? (preferences.getDouble(_parentTextScaleKey) ?? 1.0)
                .clamp(0.85, 1.5)
                .toDouble()
            : 1.0;
    _biometricEnabled =
        widget.role == MobileRole.parent &&
        (preferences.getBool(_parentBiometricKey) ?? false);
    if (_biometricEnabled && !skipBiometric) {
      final unlocked = await _authenticateParentOnDevice();
      if (!unlocked) {
        _biometricLocked = true;
        if (mounted) setState(() => _loading = false);
        return;
      }
      _biometricLocked = false;
    }
    if (FirebaseServices.ready) {
      await FirebaseServices.setAnalyticsConsent(_analyticsConsent);
    }
    if (savedUrl != null && _hubMode) {
      _api.baseUrl = savedUrl;
      _schoolId ??= await _api.readCachedSchoolId();
      final fingerprint = await _api.readHubFingerprint();
      if (fingerprint != null) {
        try {
          await _api.configureLocalHub(
            baseUrl: savedUrl,
            fingerprint: fingerprint,
            platform: Platform.isIOS ? 'ios' : 'android',
          );
          final token = await _api.readToken();
          if (token != null) {
            try {
              final response = await _api.currentUser();
              final user = response['user'] as Map<String, dynamic>;
              if (user['role'] == widget.role.apiValue) {
                final cachedUser = await _api.readCachedUser();
                final cachedSchoolId = await _api.readCachedSchoolId();
                _legacyCacheMatchesAccount = _sameCachedAccount(
                  cachedUser,
                  cachedSchoolId,
                  user,
                  _schoolId ?? '',
                );
                _user = user;
                _signedIn = true;
                await _api.saveCachedUser(user, _schoolId ?? '');
              } else {
                await _api.clearToken();
              }
            } on ApiException catch (error) {
              final cachedUser = await _api.readCachedUser();
              if (error.statusCode == null &&
                  cachedUser != null &&
                  cachedUser['role'] == widget.role.apiValue) {
                _legacyCacheMatchesAccount = _sameCachedAccount(
                  cachedUser,
                  await _api.readCachedSchoolId(),
                  cachedUser,
                  _schoolId ?? '',
                );
                _user = cachedUser;
                _signedIn = true;
                _offline = true;
              } else {
                await _api.clearToken();
              }
            }
          }
        } on ApiException catch (error) {
          _error = error.message;
        }
      } else {
        _error =
            'This saved Hub connection has no trusted certificate. Pair again using a current code.';
      }
    } else if (savedUrl != null) {
      _api.baseUrl = savedUrl;
      try {
        await _loadServerState();
        final token = await _api.readToken();
        if (token != null && _setupStatus?['access_ready'] == true) {
          try {
            final response = await _api.currentUser();
            final user = response['user'] as Map<String, dynamic>;
            if (user['role'] == widget.role.apiValue ||
                user['role'] == 'school_admin') {
              if (user['role'] == 'parent') {
                final schoolId =
                    (user['school'] as Map?)?['id']?.toString() ?? '';
                await _api.saveCachedUser(user, schoolId);
                await _loadHostedParentData(user: user);
              }
              _user = user;
              _signedIn = true;
              _offline = false;
              if (FirebaseServices.ready &&
                  preferences.getBool('school_erp_notifications_enabled') ==
                      true) {
                unawaited(_registerNotificationsIfPermitted());
              }
            } else {
              await _api.clearToken();
            }
          } on ApiException catch (error) {
            final restored =
                error.statusCode == null
                    ? await _restoreHostedParentOffline()
                    : false;
            if (!restored) await _api.clearToken();
          }
        }
      } on ApiException catch (error) {
        final restored = await _restoreHostedParentOffline();
        if (!restored) _error = error.message;
      }
    }
    if (mounted) {
      setState(() => _loading = false);
      unawaited(_checkForAppUpdate());
    }
  }

  Future<void> _checkForAppUpdate() async {
    if (_updatePromptShown ||
        _updateCheckRunning ||
        _hubMode ||
        _api.baseUrl == null ||
        (!Platform.isAndroid && !Platform.isIOS))
      return;
    _updateCheckRunning = true;
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final update = await _api.appUpdate(
        app: widget.role.apiValue,
        platform: Platform.isIOS ? 'ios' : 'android',
        version: packageInfo.version,
      );
      if (!mounted || update['updateAvailable'] != true) return;
      final updateKey =
          '${update['latestVersion']}:${update['minimumVersion']}:${update['required']}';
      if (_dismissedUpdateKey == updateKey) return;
      final link = Uri.tryParse(update['downloadUrl']?.toString() ?? '');
      if (link == null || link.scheme != 'https') return;
      _updatePromptShown = true;
      final required = update['required'] == true;
      await showDialog<void>(
        context: context,
        barrierDismissible: !required,
        builder:
            (dialogContext) => AlertDialog(
              title: Text(required ? 'Update required' : 'Update available'),
              content: Text(
                [
                  'Version ${update['latestVersion']} is available.',
                  if ((update['releaseNotes']?.toString() ?? '').isNotEmpty)
                    update['releaseNotes'].toString(),
                  if (required) 'Update this app to continue.',
                ].join('\n\n'),
              ),
              actions: [
                if (!required)
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('Later'),
                  ),
                FilledButton(
                  onPressed: () async {
                    final opened = await launchUrl(
                      link,
                      mode: LaunchMode.externalApplication,
                    );
                    if (dialogContext.mounted && opened && !required)
                      Navigator.pop(dialogContext);
                  },
                  child: const Text('Get update'),
                ),
              ],
            ),
      );
      if (!required) {
        _dismissedUpdateKey = updateKey;
        _updatePromptShown = false;
      }
    } catch (_) {
      // Update checks are best effort; sign-in and offline school access remain available.
    } finally {
      _updateCheckRunning = false;
    }
  }

  Future<bool> _authenticateParentOnDevice() =>
      ParentBiometricService(
        PlatformParentBiometricAdapter(),
      ).unlockOnThisDevice();

  Future<void> _setParentBiometricUnlock(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    if (!enabled) {
      await preferences.setBool(_parentBiometricKey, false);
      if (mounted) setState(() => _biometricEnabled = false);
      return;
    }
    final biometrics = ParentBiometricService(PlatformParentBiometricAdapter());
    if (!await biometrics.isAvailable) {
      if (mounted) {
        setState(
          () =>
              _error =
                  'Set up a fingerprint or face unlock in your phone settings first.',
        );
      }
      return;
    }
    if (!await biometrics.enableOnThisDevice()) {
      if (mounted)
        setState(() => _error = 'Biometric check was not completed.');
      return;
    }
    await preferences.setBool(_parentBiometricKey, true);
    if (mounted) {
      setState(() {
        _biometricEnabled = true;
        _error = null;
        _success = 'Biometric unlock is enabled on this phone.';
      });
    }
  }

  Future<void> _retryParentBiometricUnlock() async {
    setState(() => _working = true);
    final unlocked = await _authenticateParentOnDevice();
    if (!mounted) return;
    if (!unlocked) {
      setState(() {
        _working = false;
        _error =
            'Biometric check was not completed. Try again or use password sign-in.';
      });
      return;
    }
    setState(() {
      _biometricLocked = false;
      _loading = true;
      _working = false;
      _error = null;
    });
    await _bootstrap(skipBiometric: true);
  }

  Future<void> _useParentPasswordInstead() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_parentBiometricKey, false);
    await _api.clearToken();
    await _api.clearCachedIdentity();
    _parentChildren = [];
    _parentCommands = [];
    _parentSupportTickets = [];
    _parentCacheCleared = false;
    _pendingSupportFingerprint = null;
    _pendingSupportOperationId = null;
    _pendingPublicSupportFingerprint = null;
    _pendingPublicSupportOperationId = null;
    _parentSupportAvailable = true;
    if (!mounted) return;
    setState(() {
      _biometricEnabled = false;
      _biometricLocked = false;
      _user = null;
      _signedIn = false;
      _loading = true;
      _error = null;
    });
    await _bootstrap(skipBiometric: true);
  }

  Future<void> _loadServerState() async {
    _setupStatus = await _api.setupStatus();
  }

  Future<void> _connectServer(String value) async {
    final normalized = value.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.hasQuery ||
        uri.hasFragment ||
        !(uri.scheme == 'https' || _isLoopback(uri.host))) {
      setState(
        () =>
            _error =
                'Enter the full HTTPS server address ending in /api/v1. HTTP is allowed only for localhost testing.',
      );
      return;
    }
    if (!uri.path.endsWith('/api/v1')) {
      setState(() => _error = 'The server address must end in /api/v1.');
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    _api.baseUrl = normalized;
    try {
      await _loadServerState();
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_apiUrlKey, normalized);
      await preferences.setBool(_hubModeKey, false);
      _hubMode = false;
      setState(() {
        _error = null;
        _success = null;
      });
    } on ApiException catch (error) {
      _api.baseUrl = null;
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _pairWithCode(String value) async {
    setState(() {
      _working = true;
      _error = null;
      _success = null;
    });
    try {
      final code = value.trim();
      if (!code.startsWith('PAIR1.'))
        throw const ApiException(
          'Paste the one-time pairing code from the school administrator.',
        );
      final normalized = base64Url.normalize(code.substring(6));
      final decoded = jsonDecode(utf8.decode(base64Url.decode(normalized)));
      if (decoded is! Map<String, dynamic>)
        throw const ApiException('The pairing code could not be read.');
      final hubUrl = decoded['hubUrl']?.toString() ?? '';
      final fingerprint = decoded['certificateFingerprint']?.toString() ?? '';
      final schoolId = decoded['schoolId']?.toString() ?? '';
      final expiresAt = DateTime.tryParse(
        decoded['expiresAt']?.toString() ?? '',
      );
      final uri = Uri.tryParse(hubUrl);
      if (uri == null ||
          uri.scheme != 'https' ||
          !uri.path.endsWith('/api/v1') ||
          !RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(fingerprint) ||
          schoolId.isEmpty ||
          expiresAt == null ||
          !expiresAt.isAfter(DateTime.now().toUtc())) {
        throw const ApiException(
          'This pairing code is invalid or expired. Ask the school administrator for a new one.',
        );
      }
      await _api.configureLocalHub(
        baseUrl: hubUrl,
        fingerprint: fingerprint,
        platform: Platform.isIOS ? 'ios' : 'android',
      );
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_apiUrlKey, hubUrl);
      await preferences.setString(_hubSchoolIdKey, schoolId);
      await preferences.setBool(_hubModeKey, true);
      await _api.clearToken();
      await _api.clearCachedIdentity();
      final paired = await _api.redeemPairingCode(code);
      if (paired['paired'] != true)
        throw const ApiException(
          'The Hub did not confirm this device pairing.',
        );
      setState(() {
        _hubMode = true;
        _schoolId = schoolId;
        _setupStatus = null;
        _signedIn = false;
        _user = null;
        _success =
            'This device is paired with the school Hub. Sign in with the account created by your school.';
      });
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } on FormatException {
      setState(
        () =>
            _error =
                'The pairing code could not be read. Copy it again and try once more.',
      );
    } catch (_) {
      setState(
        () =>
            _error =
                'Pairing failed. Check that you are on the school Wi-Fi and request a new code.',
      );
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _signInToLocalHub(Map<String, String> values) async {
    setState(() {
      _working = true;
      _error = null;
      _success = null;
    });
    try {
      final response = await _api.loginToLocalHub(
        username: values['username']!,
        password: values['password']!,
      );
      final user = response['user'] as Map<String, dynamic>;
      if (user['role'] != widget.role.apiValue) {
        await _api.clearToken();
        throw ApiException(
          'This account is not a ${widget.role.title.toLowerCase()} account. Ask your administrator to check its role.',
        );
      }
      await _api.saveToken(response['token'] as String);
      final schoolId = _schoolId ?? await _api.readCachedSchoolId() ?? '';
      _legacyCacheMatchesAccount = _sameCachedAccount(
        await _api.readCachedUser(),
        await _api.readCachedSchoolId(),
        user,
        schoolId,
      );
      await _api.saveCachedUser(user, schoolId);
      _offline = false;
      setState(() {
        _user = user;
        _schoolId = schoolId;
        _signedIn = true;
        _success =
            _offline
                ? 'Signed in. Showing saved school data while the Hub is offline.'
                : null;
      });
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  bool _sameCachedAccount(
    Map<String, dynamic>? cachedUser,
    String? cachedSchoolId,
    Map<String, dynamic> activeUser,
    String activeSchoolId,
  ) =>
      cachedUser?['id'] == activeUser['id'] &&
      cachedUser?['role'] == activeUser['role'] &&
      cachedSchoolId == activeSchoolId;

  bool _isLoopback(String host) =>
      host == 'localhost' ||
      host == '127.0.0.1' ||
      host == '::1' ||
      host == '10.0.2.2';

  Future<void> _changeServer() async {
    if (_hubMode && _schoolId != null) {
      final store = await OfflineSyncStore.open(
        schoolId: _schoolId,
        accountId: '${widget.role.apiValue}_${_user?['id'] ?? 'unknown'}',
        userId: _user?['id'] as int?,
        deviceId: await _api.deviceId(),
      );
      try {
        await store.clearIfNoPendingChanges();
      } on StateError {
        if (mounted) {
          setState(
            () =>
                _error =
                    'Sync or resolve queued changes before changing schools.',
          );
        }
        return;
      }
    }
    if (!_hubMode) await _unregisterFcmDevice();
    try {
      await _api.logout();
    } catch (_) {
      // Clear the local credential even when the server cannot be reached.
    }
    await _api.clearToken();
    await _api.clearCachedIdentity();
    if (_hubMode) await _api.clearLocalHubTrust();
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_apiUrlKey);
    await preferences.remove(_hubModeKey);
    await preferences.remove(_hubSchoolIdKey);
    setState(() {
      _signedIn = false;
      _hubMode = false;
      _offline = false;
      _schoolId = null;
      _user = null;
      _setupStatus = null;
      _api.baseUrl = null;
      _error = null;
      _success = null;
    });
  }

  Future<void> _attachGoogle() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final idToken = await _requestGoogleIdToken();
      setState(() {
        _googleIdToken = idToken;
      });
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } catch (_) {
      setState(
        () =>
            _error =
                'Google sign-in could not be completed. Check the platform OAuth configuration and try again.',
      );
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<String> _requestGoogleIdToken() async {
    const serverClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');
    const clientId = String.fromEnvironment('GOOGLE_CLIENT_ID');
    final signIn = GoogleSignIn.instance;
    if (!_googleSignInInitialized) {
      await signIn.initialize(
        clientId: clientId.isEmpty ? null : clientId,
        serverClientId: serverClientId.isEmpty ? null : serverClientId,
      );
      _googleSignInInitialized = true;
    }
    if (!signIn.supportsAuthenticate()) {
      throw const ApiException(
        'Google sign-in is not available on this device configuration yet.',
      );
    }
    final account = await signIn.authenticate();
    final idToken = account.authentication.idToken;
    if (idToken == null || idToken.isEmpty) {
      throw const ApiException(
        'Google did not return an identity token. Check the Google app configuration.',
      );
    }
    _googleEmail = account.email;
    return idToken;
  }

  Future<void> _completeSetup(Map<String, String> values) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final response = await _api.completeSetup({
        'school_name': values['school_name'],
        'admin_name': values['admin_name'],
        'email': values['email'],
        'password': values['password'],
        if (_googleIdToken != null) 'google_id_token': _googleIdToken,
        if (values['activation_code']?.isNotEmpty == true)
          'activation_code': values['activation_code'],
      });
      await _api.saveToken(response['token'] as String);
      await _loadServerState();
      setState(() {
        _setupJustCompleted = true;
        _user = response['user'] as Map<String, dynamic>;
        _signedIn = true;
        _googleIdToken = null;
        _success =
            _setupStatus?['trial_enabled'] == true
                ? 'School setup is complete. Trial access is active; Google account and server activation checks were bypassed.'
                : 'School setup is complete and the required account and server checks passed.';
      });
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _activateSchool(String activationCode) async {
    final identityToken = _googleIdToken;
    if (identityToken == null) {
      setState(
        () =>
            _error =
                'Attach the Google account used for the initial school setup first.',
      );
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await _api.activateSetup(
        googleIdToken: identityToken,
        activationCode: activationCode.trim(),
      );
      await _loadServerState();
      setState(() {
        _googleIdToken = null;
        _success =
            'Google account and server activation are verified. Sign in to continue.';
      });
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _signIn(Map<String, String> values) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final role = values['role'] ?? widget.role.apiValue;
      final googleIdToken =
          role == 'school_admin' ? null : await _requestGoogleIdToken();
      var response =
          role == 'school_admin'
              ? await _api.login(
                email: values['email']!,
                password: values['password']!,
                role: role,
                schoolId: values['schoolId'],
              )
              : await _api.loginWithGoogle(
                email: values['email']!,
                phone: values['phone']!,
                role: role,
                googleIdToken: googleIdToken!,
                schoolId: values['schoolId'],
              );
      if (response['requiresSchoolSelection'] == true) {
        final selectedSchoolId = await _chooseSchool(response['schools']);
        if (selectedSchoolId == null) {
          throw const ApiException('Select a school to finish signing in.');
        }
        response = await _api.loginWithGoogle(
          email: values['email']!,
          phone: values['phone']!,
          role: role,
          googleIdToken: googleIdToken!,
          schoolId: selectedSchoolId,
        );
      }
      await _api.saveToken(response['token'] as String);
      final user = response['user'] as Map<String, dynamic>;
      final schoolId = (user['school'] as Map?)?['id']?.toString() ?? '';
      await _api.saveCachedUser(user, schoolId);
      _schoolId = schoolId;
      if (user['role'] == 'parent') await _loadHostedParentData(user: user);
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(
        'school_erp_analytics_consent',
        _analyticsConsent,
      );
      await FirebaseServices.setAnalyticsConsent(_analyticsConsent);
      setState(() {
        _user = user;
        _signedIn = true;
        _success = null;
        _googleEmail = null;
      });
      if (FirebaseServices.ready &&
          preferences.getBool('school_erp_notifications_enabled') == true) {
        unawaited(_registerNotificationsIfPermitted());
      }
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<String?> _chooseSchool(Object? value) async {
    final schools = (value as List? ?? []).whereType<Map>().toList();
    if (schools.isEmpty || !mounted) return null;
    return showDialog<String>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Choose your school'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children:
                  schools.map((school) {
                    final id = school['id']?.toString() ?? '';
                    final name = school['name']?.toString() ?? 'School';
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.school_outlined),
                      title: Text(name),
                      onTap: () => Navigator.pop(dialogContext, id),
                    );
                  }).toList(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
            ],
          ),
    );
  }

  Future<OfflineSyncStore> _openHostedParentStore(
    Map<String, dynamic> user,
  ) async {
    final school = user['school'] as Map?;
    final schoolId = school?['id']?.toString() ?? '';
    return OfflineSyncStore.open(
      schoolId: schoolId,
      accountId: 'parent_${user['id'] ?? 'unknown'}',
      userId: int.tryParse(user['id']?.toString() ?? ''),
      deviceId: await _api.deviceId(),
    );
  }

  Future<void> _loadHostedParentCache({
    required Map<String, dynamic> user,
  }) async {
    final store = await _openHostedParentStore(user);
    final cache = await store.readHostedParentCache();
    if (cache != null) {
      _parentChildren = _mapRows(cache['children']);
      _parentCommands = _mapRows(cache['commands']);
    }
    _parentCommands = _mergeParentCommands(
      _parentCommands,
      await store.hostedParentOutbox(),
    );
    await _loadCachedParentNotificationPreferences(user);
  }

  String _parentNotificationPreferenceKey(Map<String, dynamic> user) =>
      '$_parentNotificationPreferencePrefix${user['id'] ?? user['email'] ?? 'parent'}';

  Map<String, bool> _parseParentNotificationPreferences(Object? value) {
    final preferences = <String, bool>{
      ..._defaultParentNotificationPreferences,
    };
    if (value is Map) {
      for (final category in preferences.keys.toList()) {
        if (value[category] is bool)
          preferences[category] = value[category] as bool;
      }
    }
    return preferences;
  }

  Future<void> _loadCachedParentNotificationPreferences(
    Map<String, dynamic> user,
  ) async {
    final storage = await SharedPreferences.getInstance();
    final encoded = storage.getString(_parentNotificationPreferenceKey(user));
    if (encoded == null) {
      _parentNotificationPreferences = {
        ..._defaultParentNotificationPreferences,
      };
      return;
    }
    try {
      _parentNotificationPreferences = _parseParentNotificationPreferences(
        jsonDecode(encoded),
      );
    } on FormatException {
      _parentNotificationPreferences = {
        ..._defaultParentNotificationPreferences,
      };
    }
  }

  Future<void> _saveCachedParentNotificationPreferences(
    Map<String, dynamic> user,
  ) async {
    final storage = await SharedPreferences.getInstance();
    await storage.setString(
      _parentNotificationPreferenceKey(user),
      jsonEncode(_parentNotificationPreferences),
    );
  }

  Future<void> _updateParentNotificationPreference(
    String category,
    bool enabled,
  ) async {
    final user = _user;
    if (user == null || !_parentNotificationPreferences.containsKey(category)) {
      return;
    }
    final priorValue = _parentNotificationPreferences[category]!;
    setState(() {
      _working = true;
      _error = null;
      _success = null;
      _parentNotificationPreferences[category] = enabled;
    });
    try {
      await _api.updateHostedParentNotificationPreference(
        category: category,
        enabled: enabled,
      );
      await _saveCachedParentNotificationPreferences(user);
      if (mounted) setState(() => _success = 'Notification preference saved.');
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _parentNotificationPreferences[category] = priorValue;
          _error = error.message;
        });
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  List<Map<String, dynamic>> _mapRows(Object? rows) =>
      (rows as List? ?? [])
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();

  List<Map<String, dynamic>> _mergeParentCommands(
    List<Map<String, dynamic>> remote,
    List<Map<String, dynamic>> local,
  ) {
    final commands = <String, Map<String, dynamic>>{
      for (final command in remote)
        if (command['operationId'] != null)
          command['operationId'].toString(): command,
    };
    for (final command in local) {
      final operationId = command['operationId']?.toString();
      if (operationId != null) commands[operationId] = command;
    }
    return commands.values.toList();
  }

  Future<bool> _restoreHostedParentOffline() async {
    final token = await _api.readToken();
    final user = await _api.readCachedUser();
    final schoolId = await _api.readCachedSchoolId();
    if (token == null || user?['role'] != 'parent' || schoolId == null) {
      return false;
    }
    _user = user;
    _schoolId = schoolId;
    _signedIn = true;
    _offline = true;
    _setupStatus = {
      'configured': true,
      'access_ready': true,
      'trial_enabled': true,
    };
    await _loadHostedParentCache(user: user!);
    _success =
        'School server is offline. Showing saved school information from your last sync.';
    return true;
  }

  Future<void> _pushHostedParentOutbox(OfflineSyncStore store) async {
    for (final command in await store.pendingHostedParentCommands()) {
      try {
        final response = await _api.submitHostedParentRequest(
          operationId: command['operationId'] as String,
          studentPublicId: command['studentPublicId'] as String,
          requestType: command['requestType'] as String,
          message: command['message'] as String,
          startsOn: command['startsOn'] as String?,
          endsOn: command['endsOn'] as String?,
        );
        await store.setHostedParentCommandStatus(
          command['operationId'] as String,
          response['status']?.toString() ?? 'queued',
        );
      } on ApiException catch (error) {
        if (error.statusCode == null) return;
        await store.setHostedParentCommandStatus(
          command['operationId'] as String,
          'rejected',
          message: error.message,
        );
      }
    }
  }

  Future<void> _loadHostedParentData({
    required Map<String, dynamic> user,
  }) async {
    await _loadCachedParentNotificationPreferences(user);
    final store = await _openHostedParentStore(user);
    try {
      await _pushHostedParentOutbox(store);
      final childrenResponse = await _api.hostedParentChildren();
      final commandsResponse = await _api.hostedParentCommands();
      try {
        final supportResponse = await _api.hostedParentSupportTickets();
        _parentSupportTickets = _mapRows(supportResponse['tickets']);
        _parentSupportAvailable = true;
      } on ApiException catch (error) {
        if (error.statusCode == 401 || error.statusCode == 403) rethrow;
        if (error.statusCode == 404) _parentSupportAvailable = false;
      }
      ApiException? notificationPreferenceError;
      try {
        final notificationResponse =
            await _api.hostedParentNotificationPreferences();
        _parentNotificationPreferences = _parseParentNotificationPreferences(
          notificationResponse['preferences'],
        );
        await _saveCachedParentNotificationPreferences(user);
      } on ApiException catch (error) {
        if (error.statusCode == null ||
            error.statusCode == 401 ||
            error.statusCode == 403) {
          rethrow;
        }
        notificationPreferenceError = error;
      }
      _parentChildren = _mapRows(childrenResponse['children']);
      final calendarBySchool = <String, List<Map<String, dynamic>>>{};
      for (final event in _mapRows(childrenResponse['calendarEvents'])) {
        final schoolId = event['schoolId']?.toString() ?? '';
        if (schoolId.isNotEmpty) {
          (calendarBySchool[schoolId] ??= []).add(event);
        }
      }
      final attachedCalendars = <String>{};
      final projectedAtBySchool = Map<String, dynamic>.from(
        childrenResponse['calendarProjectedAtBySchool'] as Map? ?? {},
      );
      for (final child in _parentChildren) {
        final schoolId = child['schoolId']?.toString() ?? '';
        child['schoolCalendar'] =
            attachedCalendars.add(schoolId)
                ? calendarBySchool[schoolId] ?? <Map<String, dynamic>>[]
                : <Map<String, dynamic>>[];
        child['schoolCalendarProjectedAt'] =
            projectedAtBySchool[schoolId]?.toString() ??
            childrenResponse['calendarProjectedAt']?.toString();
      }
      _parentCommands = _mergeParentCommands(
        _mapRows(commandsResponse['commands']),
        await store.hostedParentOutbox(),
      );
      await store.replaceHostedParentCache(
        children: _parentChildren,
        commands: _parentCommands,
      );
      _parentCacheCleared = false;
      _error = notificationPreferenceError?.message;
      _offline = false;
    } on ApiException catch (error) {
      if (error.statusCode == 401 || error.statusCode == 403) {
        await _api.clearToken();
        await _api.clearCachedIdentity();
        _user = null;
        _signedIn = false;
        _offline = false;
        _parentChildren = [];
        _parentCommands = [];
        _parentSupportTickets = [];
        _parentCacheCleared = false;
        _pendingSupportFingerprint = null;
        _pendingSupportOperationId = null;
        _pendingPublicSupportFingerprint = null;
        _pendingPublicSupportOperationId = null;
        _error = error.message;
        rethrow;
      }
      await _loadHostedParentCache(user: user);
      _offline = error.statusCode == null;
      if (!_offline) _error = error.message;
    }
  }

  Future<void> _refreshHostedParentData() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      if (_user != null) await _loadHostedParentData(user: _user!);
    } on ApiException catch (error) {
      _error = error.message;
    }
    if (mounted) {
      setState(() {
        _working = false;
        if (_error == null) _success = 'School information refreshed.';
      });
    }
  }

  Future<void> _submitHostedParentRequest(Map<String, String> values) async {
    setState(() {
      _working = true;
      _error = null;
      _success = null;
    });
    try {
      final user = _user;
      if (user == null)
        throw const ApiException('Sign in again to submit a request.');
      final store = await _openHostedParentStore(user);
      final operationId = _api.newOperationId();
      await store.queueHostedParentCommand({
        'operationId': operationId,
        'studentPublicId': values['studentPublicId']!,
        'requestType': values['requestType']!,
        'message': values['message']!,
        'startsOn':
            values['startsOn']?.isEmpty == true ? null : values['startsOn'],
        'endsOn': values['endsOn']?.isEmpty == true ? null : values['endsOn'],
      });
      _parentCommands = await store.hostedParentOutbox();
      try {
        await _pushHostedParentOutbox(store);
        if (_api.baseUrl != null) await _loadHostedParentData(user: user);
      } on ApiException catch (error) {
        _offline = error.statusCode == null;
        if (!_offline) _error = error.message;
      }
      if (mounted) {
        setState(() {
          if (_error == null) {
            _success =
                _offline
                    ? 'Saved on this phone. Waiting for an internet connection to submit it.'
                    : 'Submitted. Waiting for the school Hub to sync this request.';
          }
        });
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _submitHostedParentSupportTicket(
    Map<String, String> values,
  ) async {
    setState(() {
      _working = true;
      _error = null;
      _success = null;
    });
    try {
      if (_user == null) {
        throw const ApiException('Sign in again to contact support.');
      }
      final fingerprint = jsonEncode([
        values['category'] ?? 'other',
        values['subject']?.trim() ?? '',
        values['message']?.trim() ?? '',
        values['studentPublicId'] ?? '',
      ]);
      if (_pendingSupportFingerprint != fingerprint ||
          _pendingSupportOperationId == null) {
        _pendingSupportFingerprint = fingerprint;
        _pendingSupportOperationId = _api.newOperationId();
      }
      final response = await _api.submitHostedParentSupportTicket(
        operationId: _pendingSupportOperationId!,
        category: values['category'] ?? 'other',
        subject: values['subject']?.trim() ?? '',
        message: values['message']?.trim() ?? '',
        studentPublicId: values['studentPublicId'],
      );
      _pendingSupportFingerprint = null;
      _pendingSupportOperationId = null;
      _parentSupportAvailable = true;
      try {
        final ticketsResponse = await _api.hostedParentSupportTickets();
        _parentSupportTickets = _mapRows(ticketsResponse['tickets']);
      } on ApiException catch (error) {
        if (error.statusCode == 401 || error.statusCode == 403) rethrow;
      }
      if (mounted) {
        setState(() {
          _success =
              'Support request ${response['reference'] ?? ''} was submitted. You can track its status below.';
        });
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _submitPublicParentLoginSupportTicket(
    Map<String, String> values,
  ) async {
    setState(() {
      _working = true;
      _error = null;
      _success = null;
    });
    try {
      final fingerprint = jsonEncode([
        values['name']?.trim() ?? '',
        values['email']?.trim().toLowerCase() ?? '',
        values['phone']?.replaceAll(RegExp(r'\D+'), '') ?? '',
        values['school']?.trim() ?? '',
        values['subject']?.trim() ?? '',
        values['message']?.trim() ?? '',
      ]);
      if (_pendingPublicSupportFingerprint != fingerprint ||
          _pendingPublicSupportOperationId == null) {
        _pendingPublicSupportFingerprint = fingerprint;
        _pendingPublicSupportOperationId = _api.newOperationId();
      }
      final response = await _api.submitPublicParentLoginSupportTicket(
        operationId: _pendingPublicSupportOperationId!,
        name: values['name']?.trim() ?? '',
        email: values['email']?.trim() ?? '',
        phone: values['phone']?.trim() ?? '',
        school: values['school'],
        subject: values['subject']?.trim() ?? '',
        message: values['message']?.trim() ?? '',
      );
      _pendingPublicSupportFingerprint = null;
      _pendingPublicSupportOperationId = null;
      if (mounted) {
        setState(() {
          _success =
              'Request ${response['reference'] ?? ''} was sent to the operator. After signing in with the same email and phone, you can follow its status in Explore.';
        });
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _clearHostedParentCache() async {
    setState(() {
      _working = true;
      _error = null;
      _success = null;
    });
    try {
      final user = _user;
      if (user == null) {
        throw const ApiException(
          'Sign in again to manage saved school information.',
        );
      }
      final store = await _openHostedParentStore(user);
      await store.clearHostedParentCache();
      _parentChildren = [];
      _parentCommands = await store.hostedParentOutbox();
      _parentSupportTickets = [];
      _parentCacheCleared = true;
      if (mounted) {
        setState(() {
          _success =
              'Saved school information was removed from this phone. Refresh when you want to download it again.';
        });
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not remove the saved school information.',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _enableNotifications() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      if (!FirebaseServices.ready) {
        throw const ApiException(
          'Firebase is not configured for this app yet. The school app can still be used after the server is connected.',
        );
      }
      final settings = await FirebaseMessaging.instance.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        throw const ApiException(
          'Notifications are off in device settings. You can enable them later.',
        );
      }
      final registration = FirebaseMessaging.instance.onRegistered.first
          .timeout(const Duration(seconds: 20));
      await _registerFirebaseMessaging();
      final fid = await registration;
      await _api.saveFcmFid(fid);
      await _api.registerFcmInstallation(
        fid,
        Platform.isIOS ? 'ios' : 'android',
      );
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool('school_erp_notifications_enabled', true);
      _startMessagingListeners();
      setState(() => _success = 'Notifications are connected on this device.');
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } catch (_) {
      setState(
        () =>
            _error =
                'Notifications could not be connected. Check app permissions and Firebase setup.',
      );
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _registerNotificationsIfPermitted() async {
    try {
      final settings =
          await FirebaseMessaging.instance.getNotificationSettings();
      if (settings.authorizationStatus != AuthorizationStatus.authorized &&
          settings.authorizationStatus != AuthorizationStatus.provisional)
        return;
      _startMessagingListeners();
      await _registerFirebaseMessaging();
    } catch (_) {
      // Sign-in and school data remain available when push registration is offline.
    }
  }

  Future<void> _registerFirebaseMessaging() async {
    if (Platform.isIOS) {
      for (var attempt = 0; attempt < 10; attempt++) {
        if (await FirebaseMessaging.instance.getAPNSToken() != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    await FirebaseMessaging.instance.register();
  }

  void _startMessagingListeners() {
    _messageSubscription ??= FirebaseMessaging.onMessage.listen(
      (message) => unawaited(_handleSchoolNotification(message, opened: false)),
    );
    _messageOpenedSubscription ??= FirebaseMessaging.onMessageOpenedApp.listen(
      (message) => unawaited(_handleSchoolNotification(message, opened: true)),
    );
    if (!_initialMessageChecked) {
      _initialMessageChecked = true;
      unawaited(_handleInitialSchoolNotification());
    }
    _tokenSubscription ??= FirebaseMessaging.instance.onRegistered.listen(
      _registerFcmInstallation,
    );
  }

  Future<void> _handleInitialSchoolNotification() async {
    try {
      final message = await FirebaseMessaging.instance.getInitialMessage();
      if (message != null) {
        await _handleSchoolNotification(message, opened: true);
      }
    } catch (_) {
      // Notifications are optional; a failed launch-message read must not block sign-in.
    }
  }

  Future<void> _handleSchoolNotification(
    RemoteMessage message, {
    required bool opened,
  }) async {
    if (!_signedIn || _user == null) return;
    final type = message.data['type']?.toString() ?? '';
    if (mounted) {
      setState(() {
        _notificationRevision++;
        _notificationType = type;
        _notificationOpened = opened;
      });
    }
    try {
      if (_hubMode) {
        // _HubWorkspace observes the revision and syncs the local school Hub.
      } else if (_user!['role'] == 'parent') {
        await _loadHostedParentData(user: _user!);
        if (mounted) setState(() {});
      } else {
        // Teacher learning records are refreshed by the paired Hub workspace.
        await _api.currentUser();
      }
    } on ApiException catch (error) {
      if (error.statusCode == 401 || error.statusCode == 403) {
        await _api.clearToken();
        if (mounted) {
          setState(() {
            _signedIn = false;
            _user = null;
            _error = error.message;
          });
        }
        return;
      }
    } catch (_) {
      // Cached school data remains visible when the network is unavailable.
    }
    if (!mounted) return;
    final text = switch (type) {
      'schedule_update' =>
        'The school schedule was updated. Open Learning to see the latest timetable and calendar.',
      'homework_update' =>
        'New homework is available. Open Learning to review the assignment and due date.',
      'school_notice' => 'A new school notice is available in Inbox.',
      _ =>
        'You have a new school update. Pull to refresh if details are not current.',
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _registerFcmInstallation(String fid) async {
    try {
      await _api.saveFcmFid(fid);
      await _api.registerFcmInstallation(
        fid,
        Platform.isIOS ? 'ios' : 'android',
      );
    } catch (_) {
      // The current token will be registered the next time the user enables push.
    }
  }

  Future<void> _signOut() async {
    if (!_hubMode) await _unregisterFcmDevice();
    try {
      await _api.logout();
    } catch (_) {
      // Clear local credentials even if the server is offline.
    }
    await _api.clearToken();
    if (mounted)
      setState(() {
        _signedIn = false;
        _user = null;
        _parentChildren = [];
        _parentCommands = [];
        _parentSupportTickets = [];
        _parentCacheCleared = false;
        _pendingSupportFingerprint = null;
        _pendingSupportOperationId = null;
        _pendingPublicSupportFingerprint = null;
        _pendingPublicSupportOperationId = null;
        _error = null;
      });
  }

  Future<void> _unregisterFcmDevice() async {
    try {
      final fid = await _api.readFcmFid();
      if (fid != null) await _api.revokeFcmInstallation(fid);
      await _api.clearFcmFid();
    } catch (_) {
      // Revocation can be retried by the school administrator if this device is offline.
    }
    if (FirebaseServices.ready) {
      try {
        await FirebaseMessaging.instance.unregister();
      } catch (_) {
        // The server record is already revoked; local notification cleanup can be retried.
      }
    }
    await _messageSubscription?.cancel();
    await _messageOpenedSubscription?.cancel();
    await _tokenSubscription?.cancel();
    _messageSubscription = null;
    _messageOpenedSubscription = null;
    _tokenSubscription = null;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('school_erp_notifications_enabled', false);
  }

  Future<void> _saveConsent(bool value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('school_erp_analytics_consent', value);
    await FirebaseServices.setAnalyticsConsent(value);
    if (mounted) setState(() => _analyticsConsent = value);
  }

  Future<void> _saveParentTextScale(double value) async {
    final textScale = value.clamp(0.85, 1.5).toDouble();
    if (mounted) setState(() => _parentTextScale = textScale);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setDouble(_parentTextScaleKey, textScale);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'School ERP ${widget.role.title}',
      debugShowCheckedModeBanner: false,
      theme: _theme,
      builder: (context, child) {
        if (widget.role != MobileRole.parent) return child ?? const SizedBox();
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: _PreferenceTextScaler(
              media.textScaler,
              _parentTextScale,
            ),
          ),
          child: child ?? const SizedBox(),
        );
      },
      home: Scaffold(
        body: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xfff2f6fc), Color(0xffe6edf6)],
            ),
          ),
          child: SafeArea(
            child:
                _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _buildBody(),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_biometricLocked) {
      return _BiometricUnlockView(
        working: _working,
        error: _error,
        onUnlock: _retryParentBiometricUnlock,
        onUsePassword: _useParentPasswordInstead,
      );
    }
    if (_api.baseUrl == null) {
      return _ServerAddressView(
        role: widget.role,
        error: _error,
        working: _working,
        onConnect: _connectServer,
        onPairCode: _pairWithCode,
      );
    }
    if (_hubMode) {
      if (_signedIn && _user != null) {
        return _HubWorkspace(
          role: widget.role,
          user: _user!,
          schoolId: _schoolId ?? '',
          api: _api,
          offlineAtLaunch: _offline,
          migrateLegacySnapshot: _legacyCacheMatchesAccount,
          biometricEnabled: _biometricEnabled,
          onBiometricChanged: _setParentBiometricUnlock,
          onSignOut: _signOut,
          onChangeServer: _changeServer,
          notificationRevision: _notificationRevision,
          notificationType: _notificationType,
          notificationOpened: _notificationOpened,
        );
      }
      return _HubLoginView(
        role: widget.role,
        error: _error,
        success: _success,
        working: _working,
        onSubmit: _signInToLocalHub,
        onChangeServer: _changeServer,
      );
    }
    if (_setupStatus?['configured'] != true) {
      return _SetupView(
        role: widget.role,
        trialEnabled: _setupStatus?['trial_enabled'] == true,
        googleEmail: _googleEmail,
        error: _error,
        success: _success,
        working: _working,
        consent: _analyticsConsent,
        onConsentChanged: _saveConsent,
        onAttachGoogle: _attachGoogle,
        onSubmit: _completeSetup,
        onChangeServer: _changeServer,
      );
    }
    if (_setupStatus?['access_ready'] != true) {
      return _GateView(
        role: widget.role,
        reason:
            'The school server is waiting for verified Google account and server activation setup.',
        googleEmail: _googleEmail,
        error: _error,
        success: _success,
        working: _working,
        onAttachGoogle: _attachGoogle,
        onActivate: _activateSchool,
        onRefresh: _refresh,
        onChangeServer: _changeServer,
      );
    }
    if (_signedIn && _user != null) {
      if (_user!['role'] == 'school_admin') {
        return _AdminView(
          role: widget.role,
          user: _user!,
          error: _error,
          success: _success,
          working: _working,
          onCreateUser: _createUser,
          onTestNotification: _sendTestNotification,
          onSignOut: _signOut,
          onChangeServer: _changeServer,
        );
      }
      return _HomeView(
        role: widget.role,
        user: _user!,
        api: _api,
        hostedParent: !_hubMode && _user!['role'] == 'parent',
        parentChildren: _parentChildren,
        parentCommands: _parentCommands,
        parentSupportTickets: _parentSupportTickets,
        parentSupportAvailable: _parentSupportAvailable,
        parentCacheCleared: _parentCacheCleared,
        analyticsConsent: _analyticsConsent,
        isOffline: _offline,
        success: _success,
        error: _error,
        working: _working,
        showWelcomeCard: FirebaseServices.showWelcomeCard,
        onEnableNotifications: _enableNotifications,
        notificationPreferences: _parentNotificationPreferences,
        onNotificationPreferenceChanged: _updateParentNotificationPreference,
        textScale: _parentTextScale,
        onTextScaleChanged: _saveParentTextScale,
        onConsentChanged: _saveConsent,
        onRefreshHostedParent: _refreshHostedParentData,
        onSubmitHostedParentRequest: _submitHostedParentRequest,
        onSubmitHostedParentSupportTicket: _submitHostedParentSupportTicket,
        onClearHostedParentCache: _clearHostedParentCache,
        onSignOut: _signOut,
        onChangeServer: _changeServer,
        biometricEnabled: _biometricEnabled,
        onBiometricChanged: _setParentBiometricUnlock,
        notificationRevision: _notificationRevision,
        notificationType: _notificationType,
        notificationOpened: _notificationOpened,
      );
    }
    return _LoginView(
      role: widget.role,
      setupJustCompleted: _setupJustCompleted,
      error: _error,
      success: _success,
      working: _working,
      consent: _analyticsConsent,
      firebaseReady: FirebaseServices.ready,
      serverUrl: _api.baseUrl!,
      onConsentChanged: _saveConsent,
      onSubmit: _signIn,
      onSubmitLoginSupport: _submitPublicParentLoginSupportTicket,
      onChangeServer: _changeServer,
    );
  }

  Future<void> _refresh() async {
    setState(() => _working = true);
    try {
      await _loadServerState();
      setState(() => _error = null);
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _createUser(Map<String, String> values) async {
    setState(() {
      _working = true;
      _error = null;
      _success = null;
    });
    try {
      final user = await _api.createUser(
        name: values['name']!,
        email: values['email']!,
        phone: values['phone']!,
        role: values['role']!,
      );
      setState(
        () =>
            _success =
                '${user['role']} account created for ${user['email']}. They sign in with this Google account and their registered phone number.',
      );
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _sendTestNotification() async {
    setState(() {
      _working = true;
      _error = null;
      _success = null;
    });
    try {
      final result = await _api.sendTestNotification();
      setState(
        () => _success = '${result['sent'] ?? 0} test notification(s) sent.',
      );
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }
}

final _theme = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xff1d5fa6),
    brightness: Brightness.light,
  ),
  scaffoldBackgroundColor: Colors.transparent,
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: const Color(0xfff4f6f8),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Color(0xffe3e9f1)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Color(0xff1d5fa6), width: 1.5),
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
  ),
  cardTheme: CardThemeData(
    color: Colors.white,
    elevation: 0,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
  ),
);

class _Page extends StatelessWidget {
  const _Page({required this.role, required this.child, this.footer});

  final MobileRole role;
  final Widget child;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            width > 520 ? 30 : 20,
            22,
            width > 520 ? 30 : 20,
            28,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _Brand(),
              const SizedBox(height: 22),
              Text(
                '${role.title} app',
                style: const TextStyle(
                  color: Color(0xff607086),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 5),
              child,
              if (footer != null) ...[const SizedBox(height: 20), footer!],
            ],
          ),
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) => Container(
    height: 76,
    alignment: Alignment.centerLeft,
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    decoration: BoxDecoration(
      color: const Color(0xff091a2b),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Image.asset(
      'packages/school_erp_mobile_shared/assets/branding/logow.png',
      width: 156,
      fit: BoxFit.contain,
    ),
  );
}

class _ServerAddressView extends StatefulWidget {
  const _ServerAddressView({
    required this.role,
    this.error,
    required this.working,
    required this.onConnect,
    required this.onPairCode,
  });
  final MobileRole role;
  final String? error;
  final bool working;
  final ValueChanged<String> onConnect;
  final ValueChanged<String> onPairCode;

  @override
  State<_ServerAddressView> createState() => _ServerAddressViewState();
}

class _ServerAddressViewState extends State<_ServerAddressView> {
  final _controller = TextEditingController();
  final _pairCodeController = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    _pairCodeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _Page(
    role: widget.role,
    child: _CardBody(
      title: 'Connect your school',
      subtitle:
          'Enter the School ERP server address provided by your school administrator.',
      error: widget.error,
      children: [
        TextField(
          controller: _controller,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Server address',
            hintText: 'https://school.example.com/api/v1',
          ),
        ),
        const SizedBox(height: 12),
        _PrimaryButton(
          label: 'Connect securely',
          working: widget.working,
          onPressed: () => widget.onConnect(_controller.text),
        ),
        const SizedBox(height: 8),
        const Text(
          'The app checks the server before showing sign-in. Use HTTPS for school servers.',
          style: TextStyle(color: Color(0xff6b788a), fontSize: 12.5),
        ),
        const Divider(height: 30),
        const Text(
          'School Hub pairing',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 5),
        const Text(
          'For a school on the same Wi-Fi, paste the one-time code from the Hub administrator. The app verifies the Hub certificate from that code.',
          style: TextStyle(
            color: Color(0xff6b788a),
            fontSize: 12.5,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _pairCodeController,
          minLines: 2,
          maxLines: 4,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'One-time pairing code',
            hintText: 'PAIR1…',
          ),
        ),
        const SizedBox(height: 10),
        _PrimaryButton(
          label: 'Pair this device',
          working: widget.working,
          onPressed: () => widget.onPairCode(_pairCodeController.text),
        ),
      ],
    ),
  );
}

class _HubLoginView extends StatefulWidget {
  const _HubLoginView({
    required this.role,
    this.error,
    this.success,
    required this.working,
    required this.onSubmit,
    required this.onChangeServer,
  });

  final MobileRole role;
  final String? error;
  final String? success;
  final bool working;
  final ValueChanged<Map<String, String>> onSubmit;
  final VoidCallback onChangeServer;

  @override
  State<_HubLoginView> createState() => _HubLoginViewState();
}

class _HubLoginViewState extends State<_HubLoginView> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _showPassword = false;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _Page(
    role: widget.role,
    child: _CardBody(
      title: 'Sign in to your school',
      subtitle:
          'This device is paired with the local School Hub. Use the username and password created by your school administrator.',
      error: widget.error,
      success: widget.success,
      children: [
        Form(
          key: _formKey,
          child: Column(
            children: [
              TextFormField(
                controller: _username,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Username'),
                validator:
                    (value) =>
                        (value?.trim().isEmpty ?? true)
                            ? 'Enter your username.'
                            : null,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _password,
                obscureText: !_showPassword,
                decoration: InputDecoration(
                  labelText: 'Password',
                  suffixIcon: IconButton(
                    tooltip: _showPassword ? 'Hide password' : 'Show password',
                    onPressed:
                        () => setState(() => _showPassword = !_showPassword),
                    icon: Icon(
                      _showPassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                  ),
                ),
                validator:
                    (value) =>
                        (value?.isEmpty ?? true)
                            ? 'Enter your password.'
                            : null,
              ),
              const SizedBox(height: 12),
              _PrimaryButton(
                label: 'Sign in',
                working: widget.working,
                onPressed: () {
                  if (_formKey.currentState?.validate() != true) return;
                  widget.onSubmit({
                    'username': _username.text.trim(),
                    'password': _password.text,
                  });
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'Your attendance drafts are saved in this device’s private app storage before they appear as queued.',
          style: TextStyle(
            color: Color(0xff6b788a),
            fontSize: 12.5,
            height: 1.4,
          ),
        ),
        TextButton(
          onPressed: widget.onChangeServer,
          child: const Text('Pair with another school'),
        ),
      ],
    ),
  );
}

class _HubWorkspace extends StatefulWidget {
  const _HubWorkspace({
    required this.role,
    required this.user,
    required this.schoolId,
    required this.api,
    required this.offlineAtLaunch,
    required this.migrateLegacySnapshot,
    required this.biometricEnabled,
    required this.onBiometricChanged,
    required this.onSignOut,
    required this.onChangeServer,
    required this.notificationRevision,
    required this.notificationType,
    required this.notificationOpened,
  });

  final MobileRole role;
  final Map<String, dynamic> user;
  final String schoolId;
  final ApiClient api;
  final bool offlineAtLaunch;
  final bool migrateLegacySnapshot;
  final bool biometricEnabled;
  final ValueChanged<bool> onBiometricChanged;
  final VoidCallback onSignOut;
  final VoidCallback onChangeServer;
  final int notificationRevision;
  final String? notificationType;
  final bool notificationOpened;

  @override
  State<_HubWorkspace> createState() => _HubWorkspaceState();
}

class _HubWorkspaceState extends State<_HubWorkspace> {
  OfflineSyncStore? _store;
  OfflineSyncService? _syncService;
  List<Map<String, dynamic>> _timetable = [];
  String? _timetableLastUpdatedAt;
  List<Map<String, dynamic>> _schoolCalendar = [];
  List<Map<String, dynamic>> _homework = [];
  List<Map<String, dynamic>> _announcements = [];
  List<Map<String, dynamic>> _examMarks = [];
  List<Map<String, dynamic>> _feeInvoices = [];
  List<Map<String, dynamic>> _feePayments = [];
  List<Map<String, dynamic>> _parentRequests = [];
  List<Map<String, Object?>> _queuedCommands = [];
  List<Map<String, Object?>> _sections = [];
  List<Map<String, Object?>> _students = [];
  List<Map<String, Object?>> _attendance = [];
  List<Map<String, dynamic>> _attendanceStatuses = [];
  Map<String, int> _counts = {};
  final Map<String, String> _draftStatuses = {};
  final _dateController = TextEditingController();
  String? _selectedSection;
  int _attendancePeriod = 0;
  String? _selectedParentStudentId;
  String _activeTab = '';
  late String _date;
  bool _showWeeklyTimetable = false;
  bool _loading = true;
  bool _busy = false;
  bool _offline = false;
  String? _message;
  Timer? _retryTimer;
  late int _handledNotificationRevision;
  bool _notificationSyncPending = false;

  @override
  void initState() {
    super.initState();
    _offline = widget.offlineAtLaunch;
    _handledNotificationRevision = widget.notificationRevision;
    _activeTab = widget.role == MobileRole.teacher ? 'Overview' : 'Children';
    final today = DateTime.now();
    _date =
        '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    _dateController.text = _date;
    unawaited(_initialize());
    _retryTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      if (mounted && !_busy) unawaited(_syncNow(showMessage: false));
    });
  }

  @override
  void didUpdateWidget(covariant _HubWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.notificationRevision == _handledNotificationRevision) return;
    _handledNotificationRevision = widget.notificationRevision;
    if (widget.notificationOpened) {
      final targetTab = switch (widget.notificationType) {
        'schedule_update' =>
          widget.role == MobileRole.parent ? 'Learning' : 'Overview',
        'homework_update' =>
          widget.role == MobileRole.parent ? 'Learning' : 'Homework',
        'school_notice' => 'Notices',
        _ => null,
      };
      if (targetTab != null && _tabs.contains(targetTab)) {
        _activeTab = targetTab;
      }
    }
    if (_busy) {
      _notificationSyncPending = true;
    } else {
      unawaited(_syncNow(showMessage: false));
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _dateController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    final store = await OfflineSyncStore.open(
      schoolId: widget.schoolId,
      accountId: '${widget.role.apiValue}_${widget.user['id'] ?? 'unknown'}',
      userId: widget.user['id'] as int?,
      deviceId: await widget.api.deviceId(),
      migrateLegacySnapshot: widget.migrateLegacySnapshot,
    );
    _store = store;
    _syncService = OfflineSyncService(api: widget.api, store: store);
    try {
      await _syncService!.refreshSnapshot();
      _offline = false;
    } on ApiException catch (error) {
      if (error.statusCode == 401 || error.statusCode == 403) {
        widget.onSignOut();
        return;
      }
      _offline = true;
    }
    await _reloadLocal();
    if (mounted) setState(() => _loading = false);
    if (!_offline && mounted) unawaited(_syncNow(showMessage: false));
  }

  Future<void> _reloadLocal() async {
    final store = _store;
    if (store == null) return;
    final sections = await store.sections();
    if (_selectedSection == null &&
        widget.role == MobileRole.teacher &&
        sections.isNotEmpty) {
      _selectedSection = sections.first['public_id']?.toString();
    }
    final attendance = await store.students(
      sectionPublicId:
          widget.role == MobileRole.teacher ? _selectedSection : null,
    );
    final marks = await store.attendanceRows();
    final queuedDrafts = await store.queuedAttendanceDrafts(
      _date,
      period: _attendancePeriod,
    );
    final attendanceStatuses = await store.mobileRecords('attendanceStatuses');
    final counts = await store.statusCounts();
    final timetable = await store.mobileRecords('timetable');
    final timetableLastUpdatedAt = await store.mobileRecordsUpdatedAt(
      'timetable',
    );
    final schoolCalendar = await store.mobileRecords('schoolCalendar');
    final homework = await store.mobileRecords('homework');
    final announcements = await store.mobileRecords('announcements');
    final examMarks = await store.mobileRecords('examMarks');
    final feeInvoices = await store.mobileRecords('feeInvoices');
    final feePayments = await store.mobileRecords('feePayments');
    final parentRequests = await store.mobileRecords('parentRequests');
    final queuedCommands = await store.queuedCommands();
    if (!mounted) return;
    setState(() {
      _sections = sections;
      _students = attendance;
      _attendance = marks;
      _attendanceStatuses = attendanceStatuses;
      _counts = counts;
      _timetable = timetable;
      _timetableLastUpdatedAt = timetableLastUpdatedAt;
      _schoolCalendar = schoolCalendar;
      _homework = homework;
      _announcements = announcements;
      _examMarks = examMarks;
      _feeInvoices = feeInvoices;
      _feePayments = feePayments;
      _parentRequests = parentRequests;
      _queuedCommands = queuedCommands;
      for (final student in attendance) {
        final id = student['public_id']?.toString() ?? '';
        Map<String, Object?>? row;
        for (final mark in marks) {
          if (mark['student_public_id'] == id &&
              mark['attendance_date'] == _date &&
              (mark['period'] ?? 0) == _attendancePeriod) {
            row = mark;
            break;
          }
        }
        _draftStatuses.putIfAbsent(
          _attendanceDraftKey(id, _attendancePeriod),
          () => row?['status']?.toString() ?? 'present',
        );
      }
      for (final draft in queuedDrafts) {
        try {
          final payload =
              jsonDecode(draft['payload_json'] as String)
                  as Map<String, dynamic>;
          final id = payload['studentPublicId']?.toString();
          if (id != null)
            _draftStatuses[_attendanceDraftKey(id, _attendancePeriod)] =
                payload['status']?.toString() ?? 'present';
        } catch (_) {
          // Ignore an unreadable older queue row and keep the last cached value.
        }
      }
    });
  }

  Future<void> _syncNow({bool showMessage = true}) async {
    final service = _syncService;
    if (service == null || _busy) return;
    setState(() {
      _busy = true;
      if (showMessage) _message = 'Syncing with the school Hub…';
    });
    try {
      final problem = await service.syncNow();
      if (problem == null) {
        _offline = false;
        _message = 'Sync complete · ${TimeOfDay.now().format(context)}';
      } else {
        _offline = true;
        if (showMessage)
          _message =
              'Offline changes stay saved on this device and will retry when the Hub is reachable.';
      }
      await _reloadLocal();
    } on ApiException catch (error) {
      if (error.statusCode == 401 || error.statusCode == 403) {
        widget.onSignOut();
        return;
      }
      _offline = true;
      if (showMessage)
        _message =
            'Offline changes stay saved on this device and will retry when the Hub is reachable.';
      await _reloadLocal();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (_notificationSyncPending) {
          _notificationSyncPending = false;
          unawaited(_syncNow(showMessage: false));
        }
      }
    }
  }

  Future<void> _retryFailed() async {
    await _store?.retryFailed();
    await _reloadLocal();
    await _syncNow();
  }

  Future<void> _queueAttendance(Map<String, Object?> student) async {
    final store = _store;
    if (store == null) return;
    final publicId = student['public_id']?.toString() ?? '';
    final current = await store.attendance(
      publicId,
      _date,
      period: _attendancePeriod,
    );
    final status =
        _draftStatuses[_attendanceDraftKey(publicId, _attendancePeriod)] ??
        'present';
    var correctionReason = '';
    if (current != null && current['status'] != status) {
      final reason = await _askCorrectionReason();
      if (reason == null || reason.trim().length < 3) return;
      correctionReason = reason.trim();
    }
    final deviceId = await widget.api.deviceId();
    await store.queueAttendance(
      schoolId: widget.schoolId,
      deviceId: deviceId,
      userId: widget.user['id'] as int,
      studentPublicId: publicId,
      date: _date,
      status: status,
      baseRevision:
          current == null ? null : int.tryParse(current['revision'].toString()),
      correctionReason: correctionReason,
      period: _attendancePeriod,
    );
    if (mounted)
      setState(
        () =>
            _message =
                'Attendance saved on this device and added to the sync queue.',
      );
    await _reloadLocal();
  }

  Future<String?> _askCorrectionReason() async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Explain this correction'),
            content: TextField(
              controller: controller,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Reason'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, controller.text),
                child: const Text('Save draft'),
              ),
            ],
          ),
    );
    controller.dispose();
    return reason;
  }

  String? _localAttendance(String studentId) {
    for (final row in _attendance) {
      if (row['student_public_id'] == studentId &&
          row['attendance_date'] == _date &&
          (row['period'] ?? 0) == _attendancePeriod) {
        final label = row['status_label']?.toString() ?? '';
        return label.isNotEmpty ? label : row['status']?.toString();
      }
    }
    return null;
  }

  String _attendanceDraftKey(String studentId, int period) =>
      '$studentId:$period';

  List<Map<String, dynamic>> get _attendanceStatusOptions =>
      _attendanceStatuses.isEmpty
          ? const [
            {'statusKey': 'present', 'label': 'Present'},
            {'statusKey': 'absent', 'label': 'Absent'},
            {'statusKey': 'late', 'label': 'Late'},
            {'statusKey': 'excused', 'label': 'Excused'},
            {'statusKey': 'early_departure', 'label': 'Early departure'},
          ]
          : _attendanceStatuses;

  List<String> get _tabs =>
      widget.role == MobileRole.teacher
          ? const [
            'Overview',
            'Attendance',
            'Homework',
            'Draft marks',
            'Notices',
          ]
          : const ['Children', 'Learning', 'Fees', 'Notices', 'Requests'];

  List<Widget> _workflowTabs() => [
    SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final tab in _tabs)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(tab),
                selected: _activeTab == tab,
                onSelected: (_) => setState(() => _activeTab = tab),
              ),
            ),
        ],
      ),
    ),
  ];

  List<Widget> _activeWorkflow() {
    if (widget.role == MobileRole.teacher) {
      switch (_activeTab) {
        case 'Attendance':
          return _teacherAttendance();
        case 'Homework':
          return [..._homeworkCards(), ..._announcementCards()];
        case 'Draft marks':
          return _teacherMarkCards();
        case 'Notices':
          return _announcementCards(allowAcknowledge: true);
        default:
          return [..._teacherOverview(), ..._homeworkCards(limit: 3)];
      }
    }
    switch (_activeTab) {
      case 'Learning':
        return _parentLearning();
      case 'Fees':
        return _parentFees();
      case 'Notices':
        return _announcementCards(allowAcknowledge: true);
      case 'Requests':
        return _parentRequestCards();
      default:
        return _parentRecords();
    }
  }

  int get _parentNavigationIndex => switch (_activeTab) {
    'Learning' => 1,
    'Notices' => 2,
    'Fees' => 3,
    'Requests' => 4,
    _ => 0,
  };

  void _selectParentNavigation(int index) {
    const tabs = ['Children', 'Learning', 'Notices', 'Fees', 'Requests'];
    setState(() => _activeTab = tabs[index]);
  }

  List<Map<String, Object?>> get _visibleParentStudents {
    final selectedId = _selectedParentStudentId;
    if (selectedId == null) return _students;
    return _students
        .where((student) => student['public_id']?.toString() == selectedId)
        .toList();
  }

  List<Widget> _teacherOverview() => [
    _sectionHeading('Today at school'),
    if (_sections.isEmpty)
      const _InfoBanner(
        text: 'No assigned classes have been synced to this account yet.',
      ),
    ..._sections.map(
      (section) => Card(
        child: ListTile(
          leading: const Icon(Icons.groups_outlined),
          title: Text('${section['class_name']} · ${section['name']}'),
          subtitle: Text(
            '${_students.where((s) => s['section_public_id'] == section['public_id']).length} students cached',
          ),
        ),
      ),
    ),
    _sectionHeading('Timetable'),
    if (_timetable.isEmpty)
      const _InfoBanner(text: 'No timetable entries are available offline.'),
    ..._timetable
        .take(12)
        .map(
          (row) => _recordCard(
            icon: Icons.schedule_outlined,
            title:
                '${row['startTime'] ?? ''}–${row['endTime'] ?? ''} · ${row['subjectName'] ?? 'Class'}',
            subtitle:
                '${row['className'] ?? ''} · ${row['sectionName'] ?? ''} · ${row['teacherName'] ?? 'Teacher not assigned'} · ${row['room'] ?? 'Room not set'}',
            trailing:
                'Day ${row['weekday'] ?? '—'} · Period ${row['period'] ?? '—'}',
            action: SchoolMeetingLinkButton(link: row['meetingLink']),
          ),
        ),
  ];

  List<Widget> _homeworkCards({int limit = 100}) => [
    _sectionHeading('Homework'),
    if (_homework.isEmpty)
      const _InfoBanner(
        text: 'No homework is available in the saved school data.',
      ),
    ..._homework
        .take(limit)
        .map(
          (row) => _recordCard(
            icon: Icons.menu_book_outlined,
            title: row['title']?.toString() ?? 'Homework',
            subtitle:
                '${row['subjectName'] ?? 'Classwork'} · ${row['className'] ?? ''} ${row['sectionName'] ?? ''} · Due ${row['dueDate'] ?? 'not set'}',
            trailing: row['status']?.toString(),
            detail: row['details']?.toString(),
          ),
        ),
  ];

  List<Widget> _teacherMarkCards() => [
    _sectionHeading('Draft examination marks'),
    if (_examMarks.isEmpty)
      const _InfoBanner(
        text: 'No assigned draft or published marks were returned by the Hub.',
      ),
    ..._examMarks.map((row) {
      final canEdit = row['examStatus'] == 'draft';
      return Card(
        child: ListTile(
          leading: Icon(canEdit ? Icons.edit_note : Icons.grading_outlined),
          title: Text(
            '${row['studentName'] ?? 'Student'} · ${row['subjectName'] ?? 'Subject'}',
          ),
          subtitle: Text(
            '${row['examTitle'] ?? 'Exam'} · ${row['marksAwarded'] ?? 'Not entered'} / ${row['maxMarks'] ?? '—'}${row['teacherNote'] == null || row['teacherNote'] == '' ? '' : ' · ${row['teacherNote']}'}',
          ),
          trailing:
              canEdit
                  ? const Icon(Icons.chevron_right)
                  : const Icon(Icons.lock_outline, size: 18),
          onTap: canEdit ? () => unawaited(_editMark(row)) : null,
        ),
      );
    }),
    ..._queuedCommands
        .where((row) => row['entity_type'] == 'exam_mark')
        .map(_queuedCommandCard),
    const _InfoBanner(
      text:
          'Draft marks save to this device first. The Hub checks your class assignment, mark range, exam state, and revision when sync resumes.',
    ),
  ];

  List<Widget> _announcementCards({bool allowAcknowledge = false}) => [
    _sectionHeading('School notices'),
    if (_announcements.isEmpty)
      const _InfoBanner(
        text: 'No notices are available in the saved school data.',
      ),
    ..._announcements.map((row) {
      final id = row['id']?.toString() ?? '';
      final acknowledged = row['acknowledged'] == true;
      final queued = _queuedCommands.any(
        (command) =>
            command['entity_type'] == 'announcement_ack' &&
            command['entity_id']?.toString() == id,
      );
      final permissions = widget.user['permissions'];
      final canAcknowledge =
          allowAcknowledge &&
          permissions is List &&
          permissions.contains('announcements.acknowledge');
      return Card(
        child: ListTile(
          leading: const Icon(Icons.campaign_outlined),
          title: Text(row['title']?.toString() ?? 'Notice'),
          subtitle: Text(
            '${row['publishOn'] ?? ''} · ${row['className'] ?? 'Whole school'}\n${row['body'] ?? ''}',
          ),
          isThreeLine: true,
          trailing:
              canAcknowledge && !acknowledged
                  ? IconButton(
                    tooltip:
                        queued
                            ? 'Acknowledgement queued'
                            : 'Acknowledge notice',
                    onPressed:
                        queued
                            ? null
                            : () => unawaited(
                              _queueCommand(
                                entityType: 'announcement_ack',
                                entityId: id,
                                operation: 'announcement.acknowledge',
                                payload: {'announcementId': int.tryParse(id)},
                              ),
                            ),
                    icon: Icon(queued ? Icons.schedule : Icons.done),
                  )
                  : Icon(
                    acknowledged
                        ? Icons.check_circle_outline
                        : Icons.chevron_right,
                  ),
        ),
      );
    }),
  ];

  List<Widget> _parentLearning() => [
    _sectionHeading('Attendance, homework and results'),
    ..._visibleParentStudents.map((student) {
      final studentId = student['student_id'];
      final studentPublicId = student['public_id'];
      final attendance = _attendance
          .where((row) => row['student_public_id'] == studentPublicId)
          .take(5);
      final homework = _homework
          .where(
            (row) =>
                row['sectionId']?.toString() ==
                student['section_id']?.toString(),
          )
          .take(5);
      final marks = _examMarks
          .where((row) => row['studentId']?.toString() == studentId?.toString())
          .take(8);
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                student['full_name']?.toString() ?? 'Student',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Text('Attendance', style: Theme.of(context).textTheme.labelLarge),
              ...attendance.map(
                (row) => Text('${row['attendance_date']} · ${row['status']}'),
              ),
              Text('Homework', style: Theme.of(context).textTheme.labelLarge),
              ...homework.map(
                (row) => Text('${row['title']} · due ${row['dueDate'] ?? '—'}'),
              ),
              Text(
                'Published results',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              ...marks.map(
                (row) => Text(
                  '${row['examTitle']} · ${row['subjectName']}: ${row['marksAwarded'] ?? 'Not entered'} / ${row['maxMarks']}',
                ),
              ),
              if (studentId == null)
                const Text('Reconnect to refresh this linked student record.'),
            ],
          ),
        ),
      );
    }),
    const SizedBox(height: 8),
    const Text('Timetable view', style: TextStyle(fontWeight: FontWeight.w700)),
    const SizedBox(height: 6),
    Text(
      timetableSyncLabel(_timetableLastUpdatedAt),
      style: const TextStyle(fontSize: 12, color: Color(0xff68778b)),
    ),
    const SizedBox(height: 6),
    SegmentedButton<bool>(
      segments: const [
        ButtonSegment<bool>(value: false, label: Text('Today')),
        ButtonSegment<bool>(value: true, label: Text('Week')),
      ],
      selected: {_showWeeklyTimetable},
      onSelectionChanged:
          (selection) => setState(() => _showWeeklyTimetable = selection.first),
    ),
    _sectionHeading('Timetable'),
    if (_timetable.isEmpty)
      const _InfoBanner(text: 'No timetable entries are available offline.'),
    if (_timetable.isNotEmpty && _visibleTimetable.isEmpty)
      _InfoBanner(
        text:
            'No classes are scheduled for ${timetableWeekdayLabel(DateTime.now().weekday)}.',
      ),
    ..._visibleTimetable
        .take(30)
        .map(
          (row) => _recordCard(
            icon: Icons.schedule_outlined,
            title:
                '${row['startTime'] ?? ''}–${row['endTime'] ?? ''} · ${row['subjectName'] ?? 'Class'}',
            subtitle:
                '${row['className'] ?? ''} · ${row['sectionName'] ?? ''} · ${row['teacherName'] ?? 'Teacher not assigned'} · ${row['room'] ?? 'Room not set'}',
            trailing:
                '${timetableWeekdayLabel(int.tryParse(row['weekday']?.toString() ?? '') ?? 0)} · Period ${row['period'] ?? '—'}',
            action: SchoolMeetingLinkButton(link: row['meetingLink']),
          ),
        ),
    _sectionHeading('School calendar'),
    if (_schoolCalendar.isEmpty)
      const _InfoBanner(text: 'No school calendar events are synced yet.'),
    ..._schoolCalendar.map((event) {
      final endDate = event['endDate']?.toString();
      final date =
          endDate == null || endDate.isEmpty
              ? '${event['startDate'] ?? ''}'
              : '${event['startDate'] ?? ''} – $endDate';
      final notes = event['notes']?.toString() ?? '';
      return _recordCard(
        icon:
            event['eventType'] == 'closure'
                ? Icons.event_busy_outlined
                : event['eventType'] == 'holiday'
                ? Icons.beach_access_outlined
                : event['eventType'] == 'exam'
                ? Icons.assignment_outlined
                : Icons.event_outlined,
        title: event['title']?.toString() ?? 'School event',
        subtitle: [
          calendarEventTypeLabel(event['eventType']),
          if (notes.isNotEmpty) notes,
        ].join(' · '),
        trailing: date,
      );
    }),
  ];

  List<Map<String, dynamic>> get _visibleTimetable {
    return timetableEntriesForView(
      _timetable,
      weekly: _showWeeklyTimetable,
      weekday: DateTime.now().weekday,
    );
  }

  List<Widget> _parentFees() => [
    _sectionHeading('Fee invoices and receipts'),
    if (_feeInvoices.isEmpty)
      const _InfoBanner(
        text: 'No fee invoices are available to this parent account.',
      ),
    ..._feeInvoices
        .where(_parentRecordMatchesSelectedStudent)
        .map(
          (row) => _recordCard(
            icon: Icons.receipt_long_outlined,
            title: '${row['feeName'] ?? 'Fee'} · ${row['period'] ?? ''}',
            subtitle:
                '${row['fullName'] ?? ''} · Due ${row['dueOn'] ?? '—'} · ${row['status'] ?? ''}',
            trailing: '₹${row['paidAmount'] ?? 0} / ₹${row['amount'] ?? 0}',
          ),
        ),
    _sectionHeading('Payments'),
    if (_feePayments.isEmpty) const Text('No recorded payments.'),
    ..._feePayments
        .where(_parentRecordMatchesSelectedStudent)
        .map(
          (row) => _recordCard(
            icon: Icons.payments_outlined,
            title: '${row['receiptNo'] ?? 'Payment'} · ${row['feeName'] ?? ''}',
            subtitle:
                '${row['fullName'] ?? ''} · ${row['paidOn'] ?? ''} · ${row['method'] ?? ''}',
            trailing: '₹${row['amount'] ?? 0} · ${row['status'] ?? ''}',
          ),
        ),
  ];

  List<Widget> _parentRequestCards() => [
    _sectionHeading('Requests'),
    Align(
      alignment: Alignment.centerRight,
      child: FilledButton.icon(
        onPressed:
            _students.isEmpty ? null : () => unawaited(_submitParentRequest()),
        icon: const Icon(Icons.add),
        label: const Text('New request'),
      ),
    ),
    if (_parentRequests.isEmpty)
      const _InfoBanner(
        text: 'Requests you submit appear here with their current status.',
      ),
    ..._parentRequests
        .where(_parentRecordMatchesSelectedStudent)
        .map(
          (row) => _recordCard(
            icon: Icons.assignment_outlined,
            title:
                '${_parentRequestTypeLabel(row['requestType'])} · ${row['studentName'] ?? 'Student'}',
            subtitle:
                '${row['startsOn'] ?? ''}${row['endsOn'] == null ? '' : ' to ${row['endsOn']}'} · ${row['message'] ?? ''}',
            trailing: row['status']?.toString(),
          ),
        ),
    ..._queuedCommands
        .where((row) => row['entity_type'] == 'parent_request')
        .map(_queuedCommandCard),
  ];

  bool _parentRecordMatchesSelectedStudent(Map<String, dynamic> row) {
    final selected = _selectedParentStudentId;
    if (selected == null) return true;
    final student = _students.cast<Map<String, Object?>?>().firstWhere(
      (item) => item?['public_id']?.toString() == selected,
      orElse: () => null,
    );
    if (student == null) return false;
    final rowPublicId = row['studentPublicId']?.toString();
    if (rowPublicId != null) return rowPublicId == selected;
    final studentId = student['student_id']?.toString();
    if (row['studentId'] != null) {
      return row['studentId'].toString() == studentId;
    }
    return row['fullName']?.toString() == student['full_name']?.toString() ||
        row['studentName']?.toString() == student['full_name']?.toString();
  }

  Widget _sectionHeading(String text) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 5),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: Color(0xff122238),
      ),
    ),
  );

  Widget _recordCard({
    required IconData icon,
    required String title,
    String? subtitle,
    String? trailing,
    String? detail,
    Widget? action,
  }) {
    final tile = ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle:
          detail == null
              ? (subtitle == null ? null : Text(subtitle))
              : Text('${subtitle ?? ''}\n$detail'),
      isThreeLine: detail != null,
      trailing:
          trailing == null
              ? null
              : Text(trailing, style: const TextStyle(fontSize: 11)),
      onTap:
          () => showDialog<void>(
            context: context,
            builder:
                (context) => AlertDialog(
                  title: Text(title),
                  content: SingleChildScrollView(
                    child: Text(
                      [
                        if (subtitle?.trim().isNotEmpty == true)
                          subtitle!.trim(),
                        if (trailing?.trim().isNotEmpty == true)
                          trailing!.trim(),
                        if (detail?.trim().isNotEmpty == true) detail!.trim(),
                      ].join('\n\n'),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                ),
          ),
    );
    return Card(
      child:
          action == null
              ? tile
              : Column(
                mainAxisSize: MainAxisSize.min,
                children: [tile, action],
              ),
    );
  }

  Widget _queuedCommandCard(Map<String, Object?> row) {
    Map<String, dynamic> payload = {};
    try {
      final decoded = jsonDecode(row['payload_json']?.toString() ?? '{}');
      if (decoded is Map) payload = Map<String, dynamic>.from(decoded);
    } catch (_) {
      // Keep a damaged local draft visible with its status and operation.
    }
    final title =
        row['entity_type'] == 'parent_request'
            ? '${_parentRequestTypeLabel(payload['requestType'])} · ${payload['studentName'] ?? 'Linked student'}'
            : row['entity_type'] == 'exam_mark'
            ? 'Draft mark · student ${payload['studentId'] ?? ''}'
            : row['operation']?.toString() ?? 'Queued change';
    final detail =
        payload['message'] ?? payload['teacherNote'] ?? row['last_error'] ?? '';
    return Card(
      child: ListTile(
        leading: const Icon(Icons.cloud_upload_outlined),
        title: Text(title),
        subtitle: Text('${row['status']} · $detail'),
      ),
    );
  }

  Future<void> _queueCommand({
    required String entityType,
    required String entityId,
    required String operation,
    required Map<String, dynamic> payload,
    int? baseRevision,
  }) async {
    final store = _store;
    if (store == null) return;
    await store.queueCommand(
      schoolId: widget.schoolId,
      deviceId: await widget.api.deviceId(),
      userId: widget.user['id'] as int,
      entityType: entityType,
      entityId: entityId,
      operation: operation,
      payload: payload,
      baseRevision: baseRevision,
    );
    if (mounted)
      setState(
        () => _message = 'Saved on this device and queued for the school Hub.',
      );
    await _reloadLocal();
    if (!_offline) unawaited(_syncNow(showMessage: false));
  }

  Future<void> _editMark(Map<String, dynamic> row) async {
    final marks = TextEditingController(
      text: row['marksAwarded']?.toString() ?? '',
    );
    final note = TextEditingController(
      text: row['teacherNote']?.toString() ?? '',
    );
    final save = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text('${row['studentName']} · ${row['subjectName']}'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: marks,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Marks out of ${row['maxMarks']}',
                  ),
                ),
                TextField(
                  controller: note,
                  decoration: const InputDecoration(labelText: 'Teacher note'),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Save draft'),
              ),
            ],
          ),
    );
    if (save == true) {
      final awarded =
          marks.text.trim().isEmpty ? null : double.tryParse(marks.text.trim());
      if (marks.text.trim().isNotEmpty &&
          (awarded == null ||
              awarded < 0 ||
              awarded > (double.tryParse('${row['maxMarks']}') ?? 0))) {
        if (mounted)
          setState(
            () => _message = 'Enter a mark within the exam subject maximum.',
          );
      } else {
        final studentId = row['studentId'] as int;
        final examId = row['examId'] as int;
        final subjectId = row['examSubjectId'] as int;
        final updated = {
          ...row,
          'marksAwarded': awarded,
          'teacherNote': note.text.trim(),
        };
        await _store?.saveMobileRecord('examMarks', updated);
        await _queueCommand(
          entityType: 'exam_mark',
          entityId: '$examId:$subjectId:$studentId',
          operation: 'exam.mark',
          payload: {
            'examId': examId,
            'examSubjectId': subjectId,
            'studentId': studentId,
            'marksAwarded': awarded,
            'teacherNote': note.text.trim(),
          },
          baseRevision:
              row['revision'] == null
                  ? null
                  : int.tryParse('${row['revision']}'),
        );
      }
    }
    marks.dispose();
    note.dispose();
  }

  Future<void> _submitParentRequest() async {
    final message = TextEditingController();
    final startsOn = TextEditingController();
    final endsOn = TextEditingController();
    final formKey = GlobalKey<FormState>();
    var studentId = int.tryParse('${_students.first['student_id']}');
    var type = 'leave';
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  title: const Text('Submit a request'),
                  content: Form(
                    key: formKey,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DropdownButtonFormField<int>(
                            initialValue: studentId,
                            decoration: const InputDecoration(
                              labelText: 'Student',
                            ),
                            items:
                                _students
                                    .map(
                                      (student) => DropdownMenuItem(
                                        value: int.tryParse(
                                          '${student['student_id']}',
                                        ),
                                        child: Text(
                                          student['full_name']?.toString() ??
                                              'Student',
                                        ),
                                      ),
                                    )
                                    .where((item) => item.value != null)
                                    .toList(),
                            onChanged:
                                (value) =>
                                    setDialogState(() => studentId = value),
                          ),
                          DropdownButtonFormField<String>(
                            initialValue: type,
                            decoration: const InputDecoration(
                              labelText: 'Request type',
                            ),
                            items:
                                const [
                                      'leave',
                                      'profile_change',
                                      'document',
                                      'data_access',
                                      'data_correction',
                                      'data_deletion',
                                      'attendance_correction',
                                      'other',
                                    ]
                                    .map(
                                      (value) => DropdownMenuItem(
                                        value: value,
                                        child: Text(
                                          _parentRequestTypeLabel(value),
                                        ),
                                      ),
                                    )
                                    .toList(),
                            onChanged:
                                (value) => setDialogState(
                                  () => type = value ?? 'other',
                                ),
                          ),
                          if (type.startsWith('data_'))
                            const _InfoBanner(
                              text:
                                  'This is sent to the school for review. It does not automatically change or delete records. The school must check its record-retention rules before acting.',
                            ),
                          if (type == 'attendance_correction')
                            const _InfoBanner(
                              text:
                                  'This asks the school to review attendance for the selected date. It does not change the official attendance record automatically.',
                            ),
                          if (type == 'leave') ...[
                            TextFormField(
                              controller: startsOn,
                              decoration: const InputDecoration(
                                labelText: 'Starts on (YYYY-MM-DD, optional)',
                              ),
                              validator:
                                  (value) => validateOptionalIsoDate(
                                    value,
                                    label: 'start date',
                                  ),
                            ),
                            TextFormField(
                              controller: endsOn,
                              decoration: const InputDecoration(
                                labelText: 'Ends on (YYYY-MM-DD, optional)',
                              ),
                              validator:
                                  (value) =>
                                      validateOptionalIsoDate(
                                        value,
                                        label: 'end date',
                                      ) ??
                                      validateOptionalRequestDateRange(
                                        startsOn: startsOn.text,
                                        endsOn: value,
                                      ),
                            ),
                          ] else if (type == 'attendance_correction') ...[
                            TextFormField(
                              controller: startsOn,
                              readOnly: true,
                              decoration: const InputDecoration(
                                labelText: 'Attendance date',
                                hintText: 'Choose the date to review',
                                suffixIcon: Icon(Icons.calendar_today_outlined),
                              ),
                              onTap: () async {
                                final today = DateUtils.dateOnly(
                                  DateTime.now(),
                                );
                                final existing = DateTime.tryParse(
                                  startsOn.text,
                                );
                                final initial =
                                    existing != null && !existing.isAfter(today)
                                        ? existing
                                        : today;
                                final selected = await showDatePicker(
                                  context: context,
                                  initialDate: initial,
                                  firstDate: DateTime(2000),
                                  lastDate: today,
                                );
                                if (selected != null) {
                                  startsOn.text = selected
                                      .toIso8601String()
                                      .substring(0, 10);
                                  setDialogState(() {});
                                }
                              },
                              validator: validateAttendanceCorrectionDate,
                            ),
                          ],
                          TextFormField(
                            controller: message,
                            minLines: 2,
                            maxLines: 4,
                            decoration: InputDecoration(
                              labelText:
                                  type.startsWith('data_')
                                      ? 'Details for the school'
                                      : 'Message',
                            ),
                            validator:
                                (value) =>
                                    (value?.trim().length ?? 0) < 3
                                        ? 'Enter at least 3 characters.'
                                        : null,
                          ),
                        ],
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () {
                        if (formKey.currentState?.validate() != true) return;
                        Navigator.pop(context, {
                          'studentId': studentId,
                          'type': type,
                          'startsOn': startsOn.text.trim(),
                          'endsOn': type == 'leave' ? endsOn.text.trim() : '',
                          'message': message.text.trim(),
                        });
                      },
                      child: const Text('Queue request'),
                    ),
                  ],
                ),
          ),
    );
    message.dispose();
    startsOn.dispose();
    endsOn.dispose();
    if (result == null) return;
    final text = result['message'] as String;
    if (result['studentId'] == null || text.length < 3) {
      if (mounted)
        setState(
          () =>
              _message =
                  'Select a linked student and enter a message of at least three characters.',
        );
      return;
    }
    final student = _students.firstWhere(
      (row) => '${row['student_id']}' == '${result['studentId']}',
    );
    await _queueCommand(
      entityType: 'parent_request',
      entityId: 'local-${DateTime.now().microsecondsSinceEpoch}',
      operation: 'parent_request.submit',
      payload: {
        'studentId': result['studentId'],
        'requestType': result['type'],
        'startsOn': result['startsOn'],
        'endsOn': result['endsOn'],
        'message': text,
        'studentName': student['full_name'],
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final pending = (_counts['pending'] ?? 0) + (_counts['failed'] ?? 0);
    final page = _Page(
      role: widget.role,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Hello, ${widget.user['displayName'] ?? widget.role.title}',
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: Color(0xff122238),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            widget.role == MobileRole.teacher
                ? 'Your assigned classes and attendance'
                : 'Your linked students and attendance',
            style: const TextStyle(color: Color(0xff68778b)),
          ),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(15),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _offline
                            ? Icons.cloud_off_outlined
                            : Icons.cloud_done_outlined,
                        color:
                            _offline
                                ? const Color(0xff9b671c)
                                : const Color(0xff26744e),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _offline
                              ? 'Offline · saved data is available'
                              : 'Connected to school Hub',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Sync now',
                        onPressed: _busy ? null : () => unawaited(_syncNow()),
                        icon:
                            _busy
                                ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                : const Icon(Icons.sync),
                      ),
                    ],
                  ),
                  Text(
                    '${_counts['pending'] ?? 0} queued · ${_counts['accepted'] ?? 0} accepted · ${_counts['failed'] ?? 0} retryable · ${_counts['conflict'] ?? 0} conflicts · ${_counts['rejected'] ?? 0} rejected',
                    style: const TextStyle(
                      color: Color(0xff69788d),
                      fontSize: 12,
                    ),
                  ),
                  if (pending > 0)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _busy ? null : _retryFailed,
                        child: const Text('Retry failed changes'),
                      ),
                    ),
                  if (_message != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        _message!,
                        style: const TextStyle(
                          color: Color(0xff49627f),
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (widget.role == MobileRole.parent && _students.length > 1)
            DropdownButtonFormField<String?>(
              initialValue: _selectedParentStudentId,
              decoration: const InputDecoration(
                labelText: 'Showing information for',
              ),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('All children'),
                ),
                ..._students.map(
                  (student) => DropdownMenuItem<String?>(
                    value: student['public_id']?.toString(),
                    child: Text(student['full_name']?.toString() ?? 'Student'),
                  ),
                ),
              ],
              onChanged:
                  (value) => setState(() => _selectedParentStudentId = value),
            ),
          if (widget.role == MobileRole.parent && _students.length > 1)
            const SizedBox(height: 10),
          if (widget.role == MobileRole.teacher) ..._workflowTabs(),
          const SizedBox(height: 12),
          ..._activeWorkflow(),
          const SizedBox(height: 10),
          if (widget.role == MobileRole.parent)
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Use phone biometrics'),
              subtitle: const Text(
                'Unlock this saved session on this phone. School access is still checked by the server.',
              ),
              value: widget.biometricEnabled,
              onChanged: widget.onBiometricChanged,
            ),
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.user['username']?.toString() ?? '',
                  style: const TextStyle(
                    color: Color(0xff6c7a8e),
                    fontSize: 12,
                  ),
                ),
              ),
              TextButton(
                onPressed: widget.onSignOut,
                child: const Text('Sign out'),
              ),
            ],
          ),
          TextButton(
            onPressed: widget.onChangeServer,
            child: const Text('Pair with another school'),
          ),
        ],
      ),
    );
    if (widget.role != MobileRole.parent) return page;
    return Scaffold(
      body: page,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _parentNavigationIndex,
        onDestinationSelected: _selectParentNavigation,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
          NavigationDestination(
            icon: Icon(Icons.menu_book_outlined),
            label: 'Learning',
          ),
          NavigationDestination(
            icon: Icon(Icons.inbox_outlined),
            label: 'Inbox',
          ),
          NavigationDestination(
            icon: Icon(Icons.payments_outlined),
            label: 'Payments',
          ),
          NavigationDestination(
            icon: Icon(Icons.explore_outlined),
            label: 'Explore',
          ),
        ],
      ),
    );
  }

  List<Widget> _teacherAttendance() {
    return [
      const Text(
        'Attendance drafts',
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: Color(0xff122238),
        ),
      ),
      const SizedBox(height: 8),
      if (_sections.isNotEmpty)
        DropdownButtonFormField<String>(
          initialValue: _selectedSection,
          decoration: const InputDecoration(
            labelText: 'Assigned class and section',
          ),
          items:
              _sections
                  .map(
                    (section) => DropdownMenuItem(
                      value: section['public_id']?.toString(),
                      child: Text(
                        '${section['class_name']} · ${section['name']}',
                      ),
                    ),
                  )
                  .toList(),
          onChanged: (value) async {
            setState(() => _selectedSection = value);
            await _reloadLocal();
          },
        ),
      const SizedBox(height: 8),
      DropdownButtonFormField<int>(
        initialValue: _attendancePeriod,
        decoration: const InputDecoration(labelText: 'Attendance session'),
        items: [
          const DropdownMenuItem(value: 0, child: Text('Full day')),
          for (var period = 1; period <= 15; period++)
            DropdownMenuItem(value: period, child: Text('Period $period')),
        ],
        onChanged: (value) async {
          if (value == null) return;
          setState(() => _attendancePeriod = value);
          await _reloadLocal();
        },
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _dateController,
        keyboardType: TextInputType.datetime,
        decoration: InputDecoration(
          labelText: 'Attendance date (YYYY-MM-DD)',
          suffixIcon: IconButton(
            icon: const Icon(Icons.check),
            onPressed: () async {
              final value = _dateController.text.trim();
              if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
                setState(() => _date = value);
                await _reloadLocal();
              }
            },
          ),
        ),
        onSubmitted: (value) async {
          if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
            setState(() => _date = value);
            await _reloadLocal();
          }
        },
      ),
      const SizedBox(height: 8),
      if (_students.isEmpty)
        const _InfoBanner(
          text:
              'No assigned students are cached yet. Connect to the school Hub while on the school network, then sync.',
        ),
      ..._students.map((student) {
        final id = student['public_id']?.toString() ?? '';
        final current = _localAttendance(id);
        final draftKey = _attendanceDraftKey(id, _attendancePeriod);
        final selectedStatus = _draftStatuses[draftKey] ?? 'present';
        return Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        student['full_name']?.toString() ?? '',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '${student['admission_no']} · ${current ?? 'Not marked'}',
                        style: const TextStyle(
                          color: Color(0xff718095),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                DropdownButton<String>(
                  value:
                      _attendanceStatusOptions.any(
                            (option) =>
                                option['statusKey']?.toString() ==
                                selectedStatus,
                          )
                          ? selectedStatus
                          : _attendanceStatusOptions.first['statusKey']
                              ?.toString(),
                  items:
                      _attendanceStatusOptions
                          .map(
                            (option) => DropdownMenuItem(
                              value: option['statusKey']?.toString(),
                              child: Text(
                                option['label']?.toString() ??
                                    option['statusKey']?.toString() ??
                                    'Status',
                              ),
                            ),
                          )
                          .toList(),
                  onChanged: (value) {
                    if (value != null)
                      setState(() => _draftStatuses[draftKey] = value);
                  },
                ),
                IconButton(
                  tooltip: 'Save on device',
                  onPressed: () => unawaited(_queueAttendance(student)),
                  icon: const Icon(Icons.save_outlined),
                ),
              ],
            ),
          ),
        );
      }),
      const SizedBox(height: 4),
      const Text(
        'Each change is written to the offline queue before the app reports it as saved. The app retries in the foreground when the Hub is reachable.',
        style: TextStyle(color: Color(0xff6b788a), fontSize: 12, height: 1.4),
      ),
    ];
  }

  List<Widget> _parentRecords() => [
    const Text(
      'Linked students',
      style: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: Color(0xff122238),
      ),
    ),
    const SizedBox(height: 8),
    if (_students.isEmpty)
      const _InfoBanner(
        text:
            'No linked student records are cached yet. Connect to the school Hub and sync to load the records shared with your account.',
      ),
    ..._students.map((student) {
      final id = student['public_id']?.toString() ?? '';
      final latest =
          _attendance
              .where((row) => row['student_public_id'] == id)
              .take(5)
              .toList();
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                student['full_name']?.toString() ?? '',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Text(
                '${student['class_name']} · ${student['section_name']}',
                style: const TextStyle(color: Color(0xff718095), fontSize: 12),
              ),
              const Divider(height: 18),
              if (latest.isEmpty)
                const Text(
                  'No attendance is available yet.',
                  style: TextStyle(color: Color(0xff718095), fontSize: 12),
                ),
              ...latest.map(
                (row) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '${row['attendance_date']} · ${row['status']}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }),
    const _InfoBanner(
      text:
          'Only records linked to your parent account are stored on this phone. Parent accounts can view attendance but cannot change it.',
    ),
  ];
}

class _SetupView extends StatefulWidget {
  const _SetupView({
    required this.role,
    required this.trialEnabled,
    this.googleEmail,
    this.error,
    this.success,
    required this.working,
    required this.consent,
    required this.onConsentChanged,
    required this.onAttachGoogle,
    required this.onSubmit,
    required this.onChangeServer,
  });
  final MobileRole role;
  final bool trialEnabled;
  final String? googleEmail;
  final String? error;
  final String? success;
  final bool working;
  final bool consent;
  final ValueChanged<bool> onConsentChanged;
  final VoidCallback onAttachGoogle;
  final ValueChanged<Map<String, String>> onSubmit;
  final VoidCallback onChangeServer;

  @override
  State<_SetupView> createState() => _SetupViewState();
}

class _SetupViewState extends State<_SetupView> {
  final _formKey = GlobalKey<FormState>();
  final _school = TextEditingController();
  final _admin = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _activation = TextEditingController();

  @override
  void dispose() {
    _school.dispose();
    _admin.dispose();
    _email.dispose();
    _password.dispose();
    _activation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _Page(
    role: widget.role,
    child: _CardBody(
      title: 'Set up this school server',
      subtitle:
          'One-time setup. The school administrator can then create teacher and parent accounts.',
      error: widget.error,
      success: widget.success,
      children: [
        _TrialBanner(enabled: widget.trialEnabled),
        const SizedBox(height: 15),
        Form(
          key: _formKey,
          child: Column(
            children: [
              TextFormField(
                controller: _school,
                decoration: const InputDecoration(labelText: 'School name'),
                validator: _required,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _admin,
                decoration: const InputDecoration(
                  labelText: 'Administrator name',
                ),
                validator: _required,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Administrator email',
                ),
                validator: _emailValidator,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Administrator password',
                  helperText: 'Use at least 12 characters',
                ),
                validator:
                    (value) =>
                        (value?.length ?? 0) < 12
                            ? 'Use at least 12 characters.'
                            : null,
              ),
              const SizedBox(height: 15),
              OutlinedButton.icon(
                onPressed: widget.working ? null : widget.onAttachGoogle,
                icon: const Icon(Icons.account_circle_outlined),
                label: Text(
                  widget.googleEmail == null
                      ? (widget.trialEnabled
                          ? 'Attach Google account (optional during trial)'
                          : 'Attach required Google account')
                      : widget.googleEmail!,
                ),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _activation,
                decoration: InputDecoration(
                  labelText:
                      widget.trialEnabled
                          ? 'Server activation code (optional during trial)'
                          : 'Required server activation code',
                ),
              ),
              const SizedBox(height: 8),
              _ConsentRow(
                value: widget.consent,
                onChanged: widget.onConsentChanged,
              ),
              const SizedBox(height: 10),
              _PrimaryButton(
                label: 'Complete school setup',
                working: widget.working,
                onPressed: () {
                  if (_formKey.currentState?.validate() != true) return;
                  widget.onSubmit({
                    'school_name': _school.text.trim(),
                    'admin_name': _admin.text.trim(),
                    'email': _email.text.trim(),
                    'password': _password.text,
                    'activation_code': _activation.text.trim(),
                  });
                },
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: widget.onChangeServer,
                child: const Text('Use another server'),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

String? _required(String? value) =>
    (value?.trim().length ?? 0) < 2 ? 'Enter at least 2 characters.' : null;

String? _emailValidator(String? value) =>
    value != null &&
            RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value.trim())
        ? null
        : 'Enter a valid email address.';

String? _phoneValidator(String? value) {
  final digits = value?.replaceAll(RegExp(r'\D'), '') ?? '';
  return digits.length >= 8 && digits.length <= 15
      ? null
      : 'Enter the phone number registered with the school.';
}

class _ParentLoginSupportDialog extends StatefulWidget {
  const _ParentLoginSupportDialog({
    required this.initialEmail,
    required this.initialPhone,
    required this.initialSchool,
  });

  final String initialEmail;
  final String initialPhone;
  final String initialSchool;

  @override
  State<_ParentLoginSupportDialog> createState() =>
      _ParentLoginSupportDialogState();
}

class _ParentLoginSupportDialogState extends State<_ParentLoginSupportDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController();
  late final _email = TextEditingController(text: widget.initialEmail);
  late final _phone = TextEditingController(text: widget.initialPhone);
  late final _school = TextEditingController(text: widget.initialSchool);
  final _subject = TextEditingController(text: 'I need help signing in');
  final _message = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    _school.dispose();
    _subject.dispose();
    _message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Parent sign-in help'),
    content: SizedBox(
      width: 460,
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                maxLength: 120,
                decoration: const InputDecoration(labelText: 'Your name'),
                validator: _required,
              ),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Gmail account'),
                validator: _emailValidator,
              ),
              TextFormField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Phone number'),
                validator: _phoneValidator,
              ),
              TextFormField(
                controller: _school,
                maxLength: 160,
                decoration: const InputDecoration(
                  labelText: 'School name or ID (optional)',
                ),
              ),
              TextFormField(
                controller: _subject,
                maxLength: 160,
                decoration: const InputDecoration(labelText: 'Subject'),
                validator:
                    (value) =>
                        (value?.trim().length ?? 0) < 4
                            ? 'Enter at least 4 characters.'
                            : null,
              ),
              TextFormField(
                controller: _message,
                minLines: 3,
                maxLines: 6,
                maxLength: 3000,
                decoration: const InputDecoration(
                  labelText: 'Describe the sign-in problem',
                  alignLabelWithHint: true,
                ),
                validator:
                    (value) =>
                        (value?.trim().length ?? 0) < 10
                            ? 'Please add at least 10 characters.'
                            : null,
              ),
              const Text(
                'This goes to the School ERP operator, who may need to verify your identity. Do not include passwords or sign-in codes. After signing in with the same email and phone, you can track it in Explore.',
                style: TextStyle(fontSize: 12, color: Color(0xff6c7a8e)),
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton.icon(
        onPressed: () {
          if (!(_formKey.currentState?.validate() ?? false)) return;
          Navigator.pop(context, {
            'name': _name.text.trim(),
            'email': _email.text.trim(),
            'phone': _phone.text.trim(),
            'school': _school.text.trim(),
            'subject': _subject.text.trim(),
            'message': _message.text.trim(),
          });
        },
        icon: const Icon(Icons.send_outlined),
        label: const Text('Send to operator'),
      ),
    ],
  );
}

class _LoginView extends StatefulWidget {
  const _LoginView({
    required this.role,
    required this.setupJustCompleted,
    this.error,
    this.success,
    required this.working,
    required this.consent,
    required this.firebaseReady,
    required this.serverUrl,
    required this.onConsentChanged,
    required this.onSubmit,
    required this.onSubmitLoginSupport,
    required this.onChangeServer,
  });
  final MobileRole role;
  final bool setupJustCompleted;
  final String? error;
  final String? success;
  final bool working;
  final bool consent;
  final bool firebaseReady;
  final String serverUrl;
  final ValueChanged<bool> onConsentChanged;
  final ValueChanged<Map<String, String>> onSubmit;
  final Future<void> Function(Map<String, String> values) onSubmitLoginSupport;
  final VoidCallback onChangeServer;

  @override
  State<_LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends State<_LoginView> {
  final _formKey = GlobalKey<FormState>();
  final _schoolId = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  bool _showPassword = false;
  String _selectedRole = '';

  @override
  void initState() {
    super.initState();
    _selectedRole = widget.role.apiValue;
  }

  @override
  void dispose() {
    _schoolId.dispose();
    _email.dispose();
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _requestLoginSupport() async {
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder:
          (_) => _ParentLoginSupportDialog(
            initialEmail: _email.text.trim(),
            initialPhone: _phone.text.trim(),
            initialSchool: _schoolId.text.trim(),
          ),
    );
    if (values != null) await widget.onSubmitLoginSupport(values);
  }

  @override
  Widget build(BuildContext context) => _Page(
    role: widget.role,
    child: _CardBody(
      title: 'Welcome back',
      subtitle: widget.role.welcome,
      error: widget.error,
      success: widget.success,
      children: [
        if (widget.setupJustCompleted)
          const _InfoBanner(
            text:
                'School setup is complete. Ask the administrator to create your teacher or parent sign-in.',
          ),
        const SizedBox(height: 12),
        Form(
          key: _formKey,
          child: Column(
            children: [
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                    value: widget.role.apiValue,
                    label: Text('${widget.role.title}'),
                  ),
                  const ButtonSegment(
                    value: 'school_admin',
                    label: Text('School admin'),
                  ),
                ],
                selected: {_selectedRole},
                onSelectionChanged:
                    (value) => setState(() => _selectedRole = value.first),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _schoolId,
                decoration: const InputDecoration(
                  labelText: 'School ID (if provided)',
                  helperText: 'Required when several schools use this server.',
                ),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Google account email',
                ),
                validator: _emailValidator,
              ),
              if (_selectedRole != 'school_admin') ...[
                const SizedBox(height: 10),
                TextFormField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Phone number registered with school',
                  ),
                  validator: _phoneValidator,
                ),
              ] else ...[
                const SizedBox(height: 10),
                TextFormField(
                  controller: _password,
                  obscureText: !_showPassword,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    suffixIcon: IconButton(
                      tooltip:
                          _showPassword ? 'Hide password' : 'Show password',
                      onPressed:
                          () => setState(() => _showPassword = !_showPassword),
                      icon: Icon(
                        _showPassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                      ),
                    ),
                  ),
                  validator:
                      (value) =>
                          (value?.isEmpty ?? true)
                              ? 'Enter your password.'
                              : null,
                ),
              ],
              const SizedBox(height: 12),
              _ConsentRow(
                value: widget.consent,
                onChanged: widget.onConsentChanged,
              ),
              const SizedBox(height: 10),
              _PrimaryButton(
                label:
                    _selectedRole == 'school_admin'
                        ? 'Sign in as school admin'
                        : 'Continue with Google',
                working: widget.working,
                onPressed: () {
                  if (_formKey.currentState?.validate() != true) return;
                  widget.onSubmit({
                    'email': _email.text.trim(),
                    'phone': _phone.text.trim(),
                    'password': _password.text,
                    'role': _selectedRole,
                    'schoolId': _schoolId.text.trim(),
                  });
                },
              ),
              const SizedBox(height: 12),
              Text(
                'Server: ${Uri.parse(widget.serverUrl).host}',
                style: const TextStyle(color: Color(0xff748196), fontSize: 12),
              ),
              TextButton(
                onPressed: widget.onChangeServer,
                child: const Text('Change school server'),
              ),
              if (widget.role == MobileRole.parent && _selectedRole == 'parent')
                TextButton.icon(
                  onPressed: widget.working ? null : _requestLoginSupport,
                  icon: const Icon(Icons.help_outline),
                  label: const Text('Need help signing in?'),
                ),
            ],
          ),
        ),
      ],
    ),
    footer: Text(
      'Analytics, crash reporting, and performance monitoring are '
      '${widget.consent ? 'enabled by your choice' : 'off'}. Firebase setup '
      '${widget.firebaseReady ? 'is ready' : 'is pending'}.',
      textAlign: TextAlign.center,
      style: const TextStyle(color: Color(0xff758196), fontSize: 11.5),
    ),
  );
}

class _AdminView extends StatefulWidget {
  const _AdminView({
    required this.role,
    required this.user,
    this.error,
    this.success,
    required this.working,
    required this.onCreateUser,
    required this.onTestNotification,
    required this.onSignOut,
    required this.onChangeServer,
  });
  final MobileRole role;
  final Map<String, dynamic> user;
  final String? error;
  final String? success;
  final bool working;
  final ValueChanged<Map<String, String>> onCreateUser;
  final VoidCallback onTestNotification;
  final VoidCallback onSignOut;
  final VoidCallback onChangeServer;

  @override
  State<_AdminView> createState() => _AdminViewState();
}

class _AdminViewState extends State<_AdminView> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  String _role = 'teacher';

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _Page(
    role: widget.role,
    child: _CardBody(
      title: 'School setup',
      subtitle:
          'Create the first teacher and parent sign-ins for ${widget.user['school']?['name'] ?? 'your school'}.',
      error: widget.error,
      success: widget.success,
      children: [
        Form(
          key: _formKey,
          child: Column(
            children: [
              DropdownButtonFormField<String>(
                initialValue: _role,
                decoration: const InputDecoration(labelText: 'Account type'),
                items: const [
                  DropdownMenuItem(value: 'teacher', child: Text('Teacher')),
                  DropdownMenuItem(value: 'parent', child: Text('Parent')),
                ],
                onChanged:
                    (value) => setState(() => _role = value ?? 'teacher'),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Full name'),
                validator: _required,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Google account email',
                ),
                validator: _emailValidator,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Phone number'),
                validator: _phoneValidator,
              ),
              const SizedBox(height: 14),
              _PrimaryButton(
                label:
                    'Create ${_role == 'teacher' ? 'teacher' : 'parent'} account',
                working: widget.working,
                onPressed: () {
                  if (_formKey.currentState?.validate() != true) return;
                  widget.onCreateUser({
                    'name': _name.text.trim(),
                    'email': _email.text.trim(),
                    'phone': _phone.text.trim(),
                    'role': _role,
                  });
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: widget.working ? null : widget.onTestNotification,
          icon: const Icon(Icons.notifications_active_outlined),
          label: const Text('Send generic test notification'),
        ),
        const SizedBox(height: 10),
        const Text(
          'This sign-in uses the hosted PHP service. To use records from the local school Hub, pair this phone with the school network.',
          style: TextStyle(color: Color(0xff718095), height: 1.4, fontSize: 12),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                widget.user['email']?.toString() ?? '',
                style: const TextStyle(fontSize: 12, color: Color(0xff6c7a8e)),
              ),
            ),
            TextButton(
              onPressed: widget.onSignOut,
              child: const Text('Sign out'),
            ),
          ],
        ),
        TextButton(
          onPressed: widget.onChangeServer,
          child: const Text('Change school server'),
        ),
      ],
    ),
  );
}

class _ActiveSessionsButton extends StatelessWidget {
  const _ActiveSessionsButton({required this.api, required this.onSignOut});

  final ApiClient api;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed:
        () => showDialog<void>(
          context: context,
          builder:
              (context) =>
                  _ActiveSessionsDialog(api: api, onSignOut: onSignOut),
        ),
    icon: const Icon(Icons.devices_outlined),
    label: const Text('Manage signed-in devices'),
  );
}

class _ActiveSessionsDialog extends StatefulWidget {
  const _ActiveSessionsDialog({required this.api, required this.onSignOut});

  final ApiClient api;
  final VoidCallback onSignOut;

  @override
  State<_ActiveSessionsDialog> createState() => _ActiveSessionsDialogState();
}

class _ActiveSessionsDialogState extends State<_ActiveSessionsDialog> {
  List<Map<String, dynamic>> _sessions = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sessions = await widget.api.activeSessions();
      if (mounted) setState(() => _sessions = sessions);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _error =
                  'Could not load signed-in devices. Try again when online.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _revoke(Map<String, dynamic> session) async {
    setState(() => _busy = true);
    try {
      final result = await widget.api.revokeSession(session['id'].toString());
      if (!mounted) return;
      if (result['signedOut'] == true) {
        Navigator.pop(context);
        widget.onSignOut();
        return;
      }
      await _refresh();
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revokeAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Sign out everywhere?'),
            content: const Text(
              'This will sign out every School ERP app session for this school account, including this phone.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Sign out all devices'),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.api.revokeAllSessions();
      if (!mounted) return;
      Navigator.pop(context);
      widget.onSignOut();
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _formatDate(Object? value) {
    if (value == null || value.toString().isEmpty) return 'Not recorded';
    final parsed = DateTime.tryParse(value.toString())?.toLocal();
    if (parsed == null) return 'Not recorded';
    final date =
        '${parsed.day.toString().padLeft(2, '0')}/${parsed.month.toString().padLeft(2, '0')}/${parsed.year}';
    final time =
        '${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}';
    return '$date · $time';
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Signed-in devices'),
    content: SizedBox(
      width: 480,
      height:
          _loading || _sessions.isEmpty
              ? 180
              : _sessions.length > 5
              ? 420
              : _sessions.length * 76 + 16,
      child:
          _loading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Color(0xffa12626)),
                      ),
                    ),
                  if (_sessions.isEmpty && _error == null)
                    const Text('No active sessions were returned.'),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children:
                          _sessions
                              .map(
                                (session) => ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(
                                    session['isCurrent'] == true
                                        ? Icons.phone_android
                                        : Icons.devices,
                                  ),
                                  title: Text(
                                    session['deviceName']
                                                ?.toString()
                                                .trim()
                                                .isNotEmpty ==
                                            true
                                        ? session['deviceName'].toString()
                                        : 'School ERP app',
                                  ),
                                  subtitle: Text(
                                    'Last active ${_formatDate(session['lastUsedAt'])} · Added ${_formatDate(session['createdAt'])}',
                                  ),
                                  trailing:
                                      session['isCurrent'] == true
                                          ? const Chip(
                                            label: Text('This phone'),
                                          )
                                          : IconButton(
                                            tooltip: 'Sign out this device',
                                            onPressed:
                                                _busy
                                                    ? null
                                                    : () => _revoke(session),
                                            icon: const Icon(Icons.logout),
                                          ),
                                ),
                              )
                              .toList(),
                    ),
                  ),
                ],
              ),
    ),
    actions: [
      TextButton(
        onPressed: _loading || _busy ? null : _refresh,
        child: const Text('Refresh'),
      ),
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Close'),
      ),
      FilledButton.tonalIcon(
        onPressed: _busy || _sessions.isEmpty ? null : _revokeAll,
        icon: const Icon(Icons.logout),
        label: const Text('Sign out all devices'),
      ),
    ],
  );
}

class _HomeView extends StatelessWidget {
  const _HomeView({
    required this.role,
    required this.user,
    required this.api,
    required this.hostedParent,
    required this.parentChildren,
    required this.parentCommands,
    required this.parentSupportTickets,
    required this.parentSupportAvailable,
    required this.parentCacheCleared,
    required this.analyticsConsent,
    required this.isOffline,
    this.success,
    this.error,
    required this.working,
    required this.showWelcomeCard,
    required this.onEnableNotifications,
    required this.notificationPreferences,
    required this.onNotificationPreferenceChanged,
    required this.textScale,
    required this.onTextScaleChanged,
    required this.onConsentChanged,
    required this.onRefreshHostedParent,
    required this.onSubmitHostedParentRequest,
    required this.onSubmitHostedParentSupportTicket,
    required this.onClearHostedParentCache,
    required this.onSignOut,
    required this.onChangeServer,
    required this.biometricEnabled,
    required this.onBiometricChanged,
    required this.notificationRevision,
    required this.notificationType,
    required this.notificationOpened,
  });
  final MobileRole role;
  final Map<String, dynamic> user;
  final ApiClient api;
  final bool hostedParent;
  final List<Map<String, dynamic>> parentChildren;
  final List<Map<String, dynamic>> parentCommands;
  final List<Map<String, dynamic>> parentSupportTickets;
  final bool parentSupportAvailable;
  final bool parentCacheCleared;
  final bool analyticsConsent;
  final bool isOffline;
  final String? success;
  final String? error;
  final bool working;
  final bool showWelcomeCard;
  final VoidCallback onEnableNotifications;
  final Map<String, bool> notificationPreferences;
  final void Function(String category, bool enabled)
  onNotificationPreferenceChanged;
  final double textScale;
  final ValueChanged<double> onTextScaleChanged;
  final ValueChanged<bool> onConsentChanged;
  final VoidCallback onRefreshHostedParent;
  final ValueChanged<Map<String, String>> onSubmitHostedParentRequest;
  final Future<void> Function(Map<String, String> values)
  onSubmitHostedParentSupportTicket;
  final Future<void> Function() onClearHostedParentCache;
  final VoidCallback onSignOut;
  final VoidCallback onChangeServer;
  final bool biometricEnabled;
  final ValueChanged<bool> onBiometricChanged;
  final int notificationRevision;
  final String? notificationType;
  final bool notificationOpened;

  @override
  Widget build(BuildContext context) {
    if (hostedParent) {
      return HostedParentNavigation(
        role: role,
        user: user,
        api: api,
        children: parentChildren,
        commands: parentCommands,
        supportTickets: parentSupportTickets,
        supportAvailable: parentSupportAvailable,
        cacheCleared: parentCacheCleared,
        analyticsConsent: analyticsConsent,
        isOffline: isOffline,
        success: success,
        error: error,
        working: working,
        showWelcomeCard: showWelcomeCard,
        onEnableNotifications: onEnableNotifications,
        notificationPreferences: notificationPreferences,
        onNotificationPreferenceChanged: onNotificationPreferenceChanged,
        textScale: textScale,
        onTextScaleChanged: onTextScaleChanged,
        onConsentChanged: onConsentChanged,
        onRefresh: onRefreshHostedParent,
        onSubmitRequest: onSubmitHostedParentRequest,
        onSubmitSupportTicket: onSubmitHostedParentSupportTicket,
        onClearCache: onClearHostedParentCache,
        onSignOut: onSignOut,
        onChangeServer: onChangeServer,
        biometricEnabled: biometricEnabled,
        onBiometricChanged: onBiometricChanged,
        notificationRevision: notificationRevision,
        notificationType: notificationType,
        notificationOpened: notificationOpened,
      );
    }

    return _Page(
      role: role,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showWelcomeCard) ...[
            Text(
              'Hello, ${user['name'] ?? role.title}',
              style: const TextStyle(
                fontSize: 25,
                height: 1.2,
                fontWeight: FontWeight.w700,
                color: Color(0xff122238),
              ),
            ),
            const SizedBox(height: 5),
            Text(
              role.welcome,
              style: const TextStyle(color: Color(0xff68778b)),
            ),
            const SizedBox(height: 16),
          ],
          if (error != null) _MessageBanner(text: error!, error: true),
          if (success != null) _MessageBanner(text: success!, error: false),
          _ActiveSessionsButton(api: api, onSignOut: onSignOut),
          if (hostedParent) ...[
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Use phone biometrics'),
              subtitle: const Text(
                'Unlock this saved session on this phone. School access is still checked by the server.',
              ),
              value: biometricEnabled,
              onChanged: onBiometricChanged,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: working ? null : onRefreshHostedParent,
                icon: const Icon(Icons.sync),
                label: const Text('Refresh school information'),
              ),
            ),
            if (parentChildren.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(17),
                  child: Text(
                    'No child has been linked to this account yet. Ask the school office to connect your parent account to your child.',
                    style: TextStyle(color: Color(0xff69788d), height: 1.45),
                  ),
                ),
              ),
            ...parentChildren.map((child) => _hostedChildCard(context, child)),
            if (parentCommands.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text(
                'Your requests',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              ...parentCommands.map(
                (command) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.outbox_outlined),
                    title: Text(
                      command['status'] == 'queued' ||
                              command['status'] == 'delivered'
                          ? 'Waiting for the school to sync'
                          : (command['message']?.toString().isNotEmpty == true
                              ? command['message'].toString()
                              : command['status'].toString()),
                    ),
                    subtitle: Text('Request ${command['operationId'] ?? ''}'),
                    trailing: Text(command['status']?.toString() ?? 'queued'),
                  ),
                ),
              ),
            ],
          ] else ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(17),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'School Hub connection',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 7),
                    const Text(
                      'No local School Hub is paired to this phone. Pair on the school network with a one-time code from the Hub administrator.',
                      style: TextStyle(color: Color(0xff69788d), height: 1.45),
                    ),
                    const SizedBox(height: 10),
                    const Row(
                      children: [
                        Icon(
                          Icons.sync_problem_outlined,
                          size: 17,
                          color: Color(0xff9b671c),
                        ),
                        SizedBox(width: 7),
                        Text(
                          'Last synced: not connected',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                            color: Color(0xff7b5b2d),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 13),
            ...role.areas.map(
              (area) => Padding(
                padding: const EdgeInsets.only(bottom: 9),
                child: Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: const Color(0xffedf3ff),
                      child: Icon(
                        _iconFor(area),
                        color: const Color(0xff2467ed),
                      ),
                    ),
                    title: Text(
                      area,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: const Text(
                      'Available after your school connects its Hub',
                    ),
                    trailing: const Icon(Icons.lock_outline, size: 18),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 5),
          _PrimaryButton(
            label: 'Enable notifications',
            working: working,
            icon: Icons.notifications_active_outlined,
            onPressed: onEnableNotifications,
          ),
          const SizedBox(height: 10),
          _ConsentRow(value: analyticsConsent, onChanged: onConsentChanged),
          const Divider(height: 28),
          Row(
            children: [
              Expanded(
                child: Text(
                  user['email']?.toString() ?? '',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff6c7a8e),
                  ),
                ),
              ),
              TextButton(onPressed: onSignOut, child: const Text('Sign out')),
            ],
          ),
          TextButton(
            onPressed: onChangeServer,
            child: const Text('Change school server'),
          ),
        ],
      ),
    );
  }

  Widget _hostedChildCard(BuildContext context, Map<String, dynamic> child) {
    final snapshot = Map<String, dynamic>.from(child['snapshot'] as Map? ?? {});
    final student = Map<String, dynamic>.from(
      snapshot['student'] as Map? ?? {},
    );
    final attendance = _snapshotRows(snapshot['attendance']);
    final timetable = _snapshotRows(snapshot['timetable']);
    final homework = _snapshotRows(snapshot['homework']);
    final announcements = _snapshotRows(snapshot['announcements']);
    final results = _snapshotRows(snapshot['results']);
    final fees = _snapshotRows(snapshot['fees']);
    final projectedAt = child['projectedAt']?.toString() ?? 'unknown';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              student['fullName']?.toString() ??
                  student['name']?.toString() ??
                  'Linked child',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            Text(
              '${student['className'] ?? ''} ${student['sectionName'] ?? ''} · ${student['admissionNo'] ?? ''}',
              style: const TextStyle(color: Color(0xff68778b)),
            ),
            Text(
              '${child['schoolName'] ?? 'School'} · ${child['linkStatus'] ?? 'Linked'}',
              style: const TextStyle(fontSize: 12, color: Color(0xff68778b)),
            ),
            const SizedBox(height: 4),
            Text(
              'Last synced ${projectedAt.replaceFirst('T', ' ').replaceFirst('Z', ' UTC')}',
              style: const TextStyle(fontSize: 11, color: Color(0xff68778b)),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                _ParentCount(label: 'Attendance', count: attendance.length),
                _ParentCount(label: 'Periods', count: timetable.length),
                _ParentCount(label: 'Homework', count: homework.length),
                _ParentCount(label: 'Results', count: results.length),
                _ParentCount(label: 'Fee records', count: fees.length),
              ],
            ),
            if (announcements.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text(
                'School notices',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              ...announcements
                  .take(3)
                  .map(
                    (row) => Text(
                      '• ${row['title'] ?? row['message'] ?? 'School notice'}',
                      style: const TextStyle(height: 1.5),
                    ),
                  ),
            ],
            if (homework.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text(
                'Homework',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              ...homework
                  .take(3)
                  .map(
                    (row) => Text(
                      '• ${row['title'] ?? 'Assignment'}${row['dueOn'] == null ? '' : ' · due ${row['dueOn']}'}',
                      style: const TextStyle(height: 1.5),
                    ),
                  ),
            ],
            if (results.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text(
                'Published results',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              ...results
                  .take(3)
                  .map(
                    (row) => Text(
                      '• ${row['examTitle'] ?? 'Exam'} · ${row['subjectName'] ?? ''} ${row['marksAwarded'] ?? ''}/${row['maxMarks'] ?? ''}',
                      style: const TextStyle(height: 1.5),
                    ),
                  ),
            ],
            if (fees.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text('Fees', style: TextStyle(fontWeight: FontWeight.w700)),
              ...fees
                  .take(3)
                  .map(
                    (row) => Text(
                      '• ${row['feeName'] ?? row['period'] ?? 'Fee'} · ${row['status'] ?? ''}',
                      style: const TextStyle(height: 1.5),
                    ),
                  ),
            ],
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed:
                  working
                      ? null
                      : () => _requestLeave(
                        context,
                        child['studentPublicId']?.toString() ?? '',
                      ),
              icon: const Icon(Icons.edit_calendar_outlined),
              label: const Text('Send a request to school'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _requestLeave(
    BuildContext context,
    String studentPublicId,
  ) async {
    if (studentPublicId.isEmpty) return;
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => const _HostedParentRequestDialog(),
    );
    if (values != null) {
      onSubmitHostedParentRequest({
        ...values,
        'studentPublicId': studentPublicId,
      });
    }
  }

  List<Map<String, dynamic>> _snapshotRows(Object? value) =>
      (value as List? ?? [])
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
}

class HostedParentNavigation extends StatefulWidget {
  const HostedParentNavigation({
    required this.role,
    required this.user,
    required this.api,
    required this.children,
    required this.commands,
    required this.supportTickets,
    required this.supportAvailable,
    required this.cacheCleared,
    required this.analyticsConsent,
    required this.isOffline,
    required this.working,
    required this.showWelcomeCard,
    required this.onEnableNotifications,
    required this.notificationPreferences,
    required this.onNotificationPreferenceChanged,
    required this.textScale,
    required this.onTextScaleChanged,
    required this.onConsentChanged,
    required this.onRefresh,
    required this.onSubmitRequest,
    required this.onSubmitSupportTicket,
    required this.onClearCache,
    required this.onSignOut,
    required this.onChangeServer,
    required this.biometricEnabled,
    required this.onBiometricChanged,
    required this.notificationRevision,
    required this.notificationType,
    required this.notificationOpened,
    this.success,
    this.error,
  });

  final MobileRole role;
  final Map<String, dynamic> user;
  final ApiClient api;
  final List<Map<String, dynamic>> children;
  final List<Map<String, dynamic>> commands;
  final List<Map<String, dynamic>> supportTickets;
  final bool supportAvailable;
  final bool cacheCleared;
  final bool analyticsConsent;
  final bool isOffline;
  final bool working;
  final bool showWelcomeCard;
  final VoidCallback onEnableNotifications;
  final Map<String, bool> notificationPreferences;
  final void Function(String category, bool enabled)
  onNotificationPreferenceChanged;
  final double textScale;
  final ValueChanged<double> onTextScaleChanged;
  final ValueChanged<bool> onConsentChanged;
  final VoidCallback onRefresh;
  final ValueChanged<Map<String, String>> onSubmitRequest;
  final Future<void> Function(Map<String, String> values) onSubmitSupportTicket;
  final Future<void> Function() onClearCache;
  final VoidCallback onSignOut;
  final VoidCallback onChangeServer;
  final bool biometricEnabled;
  final ValueChanged<bool> onBiometricChanged;
  final int notificationRevision;
  final String? notificationType;
  final bool notificationOpened;
  final String? success;
  final String? error;

  @override
  State<HostedParentNavigation> createState() => _HostedParentNavigationState();
}

class _HostedParentNavigationState extends State<HostedParentNavigation> {
  int _selectedIndex = 0;
  int _learnSectionIndex = 0;
  late int _handledNotificationRevision;
  bool _showWeeklyTimetable = false;
  String? _selectedChildId;
  DateTimeRange? _attendanceDateRange;

  @override
  void initState() {
    super.initState();
    _handledNotificationRevision = widget.notificationRevision;
  }

  @override
  void didUpdateWidget(covariant HostedParentNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.notificationRevision != _handledNotificationRevision) {
      _handledNotificationRevision = widget.notificationRevision;
      if (widget.notificationOpened) {
        _selectedIndex = switch (widget.notificationType) {
          'schedule_update' => 1,
          'homework_update' => 1,
          'school_notice' => 1,
          _ => _selectedIndex,
        };
        if (widget.notificationType == 'school_notice') {
          _learnSectionIndex = 1;
          _selectedIndex = 1;
        }
      }
    }
    if (_selectedChildId != null &&
        !widget.children.any(
          (child) => child['studentPublicId']?.toString() == _selectedChildId,
        )) {
      _selectedChildId = null;
    }
  }

  List<Map<String, dynamic>> get _visibleChildren {
    final selectedId = _selectedChildId;
    if (selectedId == null) return widget.children;
    return widget.children
        .where((child) => child['studentPublicId']?.toString() == selectedId)
        .toList();
  }

  Map<String, dynamic> _student(Map<String, dynamic> child) =>
      Map<String, dynamic>.from(
        (Map<String, dynamic>.from(child['snapshot'] as Map? ?? {}))['student']
                as Map? ??
            {},
      );

  List<Map<String, dynamic>> _rows(Map<String, dynamic> child, String key) =>
      (Map<String, dynamic>.from(child['snapshot'] as Map? ?? {})[key]
                  as List? ??
              [])
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();

  List<Map<String, dynamic>> _visibleTimetable(Map<String, dynamic> child) {
    return timetableEntriesForView(
      _rows(child, 'timetable'),
      weekly: _showWeeklyTimetable,
      weekday: DateTime.now().weekday,
    );
  }

  List<Map<String, dynamic>> _familyCalendarEvents() {
    final selectedChild = widget.children.where(
      (child) => child['studentPublicId']?.toString() == _selectedChildId,
    );
    final selectedSchoolId =
        selectedChild.isEmpty
            ? null
            : selectedChild.first['schoolId']?.toString();
    final unique = <String, Map<String, dynamic>>{};
    for (final child in widget.children) {
      for (final event
          in (child['schoolCalendar'] as List? ?? []).whereType<Map>()) {
        final value = Map<String, dynamic>.from(event);
        final schoolId = value['schoolId']?.toString() ?? '';
        if (selectedSchoolId != null && schoolId != selectedSchoolId) continue;
        final key =
            '$schoolId:${value['id'] ?? value['title']}:${value['startDate']}';
        unique.putIfAbsent(key, () => value);
      }
    }
    final events =
        unique.values.toList()..sort((left, right) {
          final date = (left['startDate']?.toString() ?? '').compareTo(
            right['startDate']?.toString() ?? '',
          );
          return date != 0
              ? date
              : (left['schoolName']?.toString() ?? '').compareTo(
                right['schoolName']?.toString() ?? '',
              );
        });
    return events;
  }

  List<Widget> _familyCalendarSection() {
    final events = _familyCalendarEvents();
    final selectedChild = widget.children.where(
      (child) => child['studentPublicId']?.toString() == _selectedChildId,
    );
    final selectedSchoolChild =
        selectedChild.isEmpty
            ? null
            : widget.children.cast<Map<String, dynamic>>().firstWhere(
              (child) =>
                  child['schoolId']?.toString() ==
                  selectedChild.first['schoolId']?.toString(),
              orElse: () => selectedChild.first,
            );
    final lastUpdated = selectedSchoolChild?['schoolCalendarProjectedAt'];
    return [
      _sectionHeading('Family calendar'),
      if (events.isEmpty)
        const _InfoBanner(text: 'No school calendar events are synced yet.'),
      ...events.map((event) {
        final endDate = event['endDate']?.toString();
        final date =
            endDate == null || endDate.isEmpty
                ? '${event['startDate'] ?? ''}'
                : '${event['startDate'] ?? ''} – $endDate';
        final notes = event['notes']?.toString() ?? '';
        final title = event['title']?.toString() ?? 'School event';
        final subtitle = [
          event['schoolName']?.toString() ?? 'School',
          calendarEventTypeLabel(event['eventType']),
          if (notes.isNotEmpty) notes,
        ].join(' · ');
        return Card(
          child: ListTile(
            leading: Icon(
              event['eventType'] == 'closure'
                  ? Icons.event_busy_outlined
                  : event['eventType'] == 'holiday'
                  ? Icons.beach_access_outlined
                  : event['eventType'] == 'exam'
                  ? Icons.assignment_outlined
                  : Icons.event_outlined,
            ),
            title: Text(title),
            subtitle: Text(subtitle),
            trailing: Text(date, style: const TextStyle(fontSize: 11)),
            onTap: () => _showRecordDetail(context, title, '$date\n$subtitle'),
          ),
        );
      }),
      if (lastUpdated != null)
        Text(
          'Calendar synced ${_syncLabel(lastUpdated)}',
          style: const TextStyle(fontSize: 11, color: Color(0xff68778b)),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xfff4f6f8),
    body: SafeArea(
      child: Column(
        children: [
          _parentV3BrandBar(context),
          if (widget.error != null ||
              widget.success != null ||
              widget.isOffline)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Column(
                children: [
                  if (widget.error != null)
                    _MessageBanner(text: widget.error!, error: true),
                  if (widget.success != null)
                    _MessageBanner(text: widget.success!, error: false),
                  if (widget.isOffline)
                    const _MessageBanner(
                      text:
                          'Offline · showing the last saved school information.',
                      error: false,
                    ),
                ],
              ),
            ),
          if (_selectedIndex == 1 && widget.children.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: _childSelector(),
            ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                  children: [
                    if (widget.showWelcomeCard && _selectedIndex == 0) ...[
                      Text(
                        'Hello, ${widget.user['name'] ?? widget.role.title}',
                        style: const TextStyle(
                          fontSize: 25,
                          height: 1.2,
                          fontWeight: FontWeight.w800,
                          color: Color(0xff122238),
                        ),
                      ),
                      const SizedBox(height: 5),
                      const Text(
                        'Your family’s school day, at a glance.',
                        style: TextStyle(color: Color(0xff68778b)),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (_selectedIndex == 0 && widget.children.isNotEmpty) ...[
                      _childSelector(),
                      const SizedBox(height: 8),
                    ],
                    if (_selectedIndex == 0) ..._parentV3Home(context),
                    if (_selectedIndex == 1) ..._parentV3Learn(context),
                    if (_selectedIndex == 2) ..._parentV3Shop(context),
                    if (_selectedIndex == 3) ..._exploreContent(context),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _selectedIndex,
      onDestinationSelected: (index) => setState(() => _selectedIndex = index),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home),
          label: 'Home',
        ),
        NavigationDestination(
          icon: Icon(Icons.school_outlined),
          selectedIcon: Icon(Icons.school),
          label: 'Learn+',
        ),
        NavigationDestination(
          icon: Icon(Icons.shopping_bag_outlined),
          selectedIcon: Icon(Icons.shopping_bag),
          label: 'Shop',
        ),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: 'Settings',
        ),
      ],
    ),
  );

  Widget _parentV3BrandBar(BuildContext context) {
    final schools =
        widget.children
            .map((child) => child['schoolName']?.toString())
            .whereType<String>()
            .where((name) => name.isNotEmpty)
            .toSet();
    final school =
        schools.isEmpty
            ? 'Family account'
            : schools.length == 1
            ? schools.first
            : 'Multiple schools';
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 14, 8),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xff1d5fa6),
              borderRadius: BorderRadius.circular(11),
            ),
            child: const Icon(
              Icons.school_rounded,
              color: Colors.white,
              size: 21,
            ),
          ),
          const SizedBox(width: 10),
          Text.rich(
            TextSpan(
              children: [
                const TextSpan(
                  text: 'IQ',
                  style: TextStyle(color: Color(0xff1d5fa6)),
                ),
                TextSpan(
                  text: 'naut',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ],
            ),
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              letterSpacing: -.4,
            ),
          ),
          Container(
            width: 1,
            height: 22,
            margin: const EdgeInsets.symmetric(horizontal: 10),
            color: const Color(0xffdce3eb),
          ),
          Expanded(
            child: Text(
              school,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xff536173),
              ),
            ),
          ),
          IconButton(
            tooltip:
                widget.isOffline ? 'Offline' : 'Refresh school information',
            onPressed: widget.working ? null : widget.onRefresh,
            icon: Icon(
              widget.isOffline ? Icons.cloud_off_outlined : Icons.sync_rounded,
              color:
                  widget.isOffline
                      ? const Color(0xffa76300)
                      : const Color(0xff1d5fa6),
            ),
          ),
          IconButton(
            tooltip: 'Settings and account',
            onPressed: () => setState(() => _selectedIndex = 3),
            icon: const CircleAvatar(
              radius: 16,
              backgroundColor: Color(0xffdceafe),
              child: Icon(
                Icons.person_outline,
                size: 19,
                color: Color(0xff1d5fa6),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _childSelector() => SizedBox(
    height: 48,
    child: ListView(
      scrollDirection: Axis.horizontal,
      children: [
        _childPill(
          label: 'All children',
          selected: _selectedChildId == null,
          onTap: () => setState(() => _selectedChildId = null),
        ),
        for (final child in widget.children)
          _childPill(
            label:
                _student(child)['fullName']?.toString().split(' ').first ??
                'Child',
            selected: _selectedChildId == child['studentPublicId']?.toString(),
            onTap:
                () => setState(
                  () => _selectedChildId = child['studentPublicId']?.toString(),
                ),
          ),
      ],
    ),
  );

  Widget _childPill({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      showCheckmark: false,
      labelStyle: TextStyle(
        fontWeight: FontWeight.w700,
        color: selected ? const Color(0xff1d5fa6) : const Color(0xff435064),
      ),
      backgroundColor: Colors.white,
      selectedColor: const Color(0xffe4efff),
      side: BorderSide(
        color: selected ? const Color(0xff1d5fa6) : const Color(0xffe1e7ef),
      ),
      shape: const StadiumBorder(),
    ),
  );

  List<Widget> _parentV3Home(BuildContext context) {
    final children = _visibleChildren;
    if (widget.children.isEmpty) {
      return [
        _sectionHeading(
          widget.cacheCleared
              ? 'School information removed'
              : 'Link your children',
        ),
        _v3Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                widget.cacheCleared
                    ? Icons.cloud_download_outlined
                    : Icons.family_restroom_outlined,
                size: 34,
                color: const Color(0xff1d5fa6),
              ),
              const SizedBox(height: 10),
              Text(
                widget.cacheCleared
                    ? 'Your saved school information was removed from this phone. Refresh to download it again.'
                    : 'No child is linked to this account yet. Ask the school office to connect your parent account.',
                style: const TextStyle(height: 1.45, color: Color(0xff536173)),
              ),
              if (widget.cacheCleared) ...[
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: widget.working ? null : widget.onRefresh,
                  icon: const Icon(Icons.sync),
                  label: const Text('Download school information'),
                ),
              ],
            ],
          ),
        ),
        _sectionHeading('Your family'),
        _v3Card(
          child: Text(
            'When the school links a child to this account, attendance, timetable, homework, results and notices will appear here.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.45,
            ),
          ),
        ),
      ];
    }

    final feeRows = <Map<String, dynamic>>[];
    final homeworkRows = <Map<String, dynamic>>[];
    final announcementRows = <Map<String, dynamic>>[];
    for (final child in children) {
      if (child['accessLevel'] == 'schedule_only') continue;
      feeRows.addAll(
        _rows(
          child,
          'fees',
        ).map((row) => {...row, '_school': child['schoolName']}),
      );
      homeworkRows.addAll(
        _rows(
          child,
          'homework',
        ).map((row) => {...row, '_student': _student(child)['fullName']}),
      );
      announcementRows.addAll(
        _rows(
          child,
          'announcements',
        ).map((row) => {...row, '_school': child['schoolName']}),
      );
    }
    final dueFees =
        feeRows.where((row) {
          final status = row['status']?.toString().toLowerCase() ?? '';
          return status.isNotEmpty &&
              !{'paid', 'cleared', 'waived', 'refunded'}.contains(status);
        }).toList();

    return [
      _sectionHeading('Your children'),
      for (final child in children) _parentV3ChildCard(context, child),
      _sectionHeading('Needs your attention'),
      _v3Card(
        child: Column(
          children: [
            _v3AttentionRow(
              icon: Icons.menu_book_outlined,
              title:
                  homeworkRows.isEmpty
                      ? 'Homework'
                      : '${homeworkRows.length} homework item${homeworkRows.length == 1 ? '' : 's'}',
              subtitle:
                  homeworkRows.isEmpty
                      ? 'No new homework has been published.'
                      : _attentionSubtitle(
                        homeworkRows.first,
                        'Due date not provided',
                      ),
              action: 'View',
              onTap:
                  () => setState(() {
                    _selectedIndex = 1;
                    _learnSectionIndex = 0;
                  }),
            ),
            const Divider(height: 20),
            _v3AttentionRow(
              icon: Icons.payments_outlined,
              title:
                  dueFees.isEmpty
                      ? 'Fee records'
                      : '${dueFees.length} fee item${dueFees.length == 1 ? '' : 's'} to review',
              subtitle:
                  dueFees.isEmpty
                      ? 'See published fee records from your school.'
                      : _attentionSubtitle(
                        dueFees.first,
                        'Check the details from your school',
                      ),
              action: 'View',
              onTap:
                  () => setState(() {
                    _selectedIndex = 1;
                    _learnSectionIndex = 2;
                  }),
            ),
            const Divider(height: 20),
            _v3AttentionRow(
              icon: Icons.notifications_none_rounded,
              title:
                  announcementRows.isEmpty
                      ? 'School notices'
                      : '${announcementRows.length} school notice${announcementRows.length == 1 ? '' : 's'}',
              subtitle:
                  announcementRows.isEmpty
                      ? 'New school notices will appear here.'
                      : announcementRows.first['title']?.toString() ??
                          'New school update',
              action: 'View',
              onTap:
                  () => setState(() {
                    _selectedIndex = 1;
                    _learnSectionIndex = 1;
                  }),
            ),
          ],
        ),
      ),
      _sectionHeading('School modules'),
      GridView.count(
        crossAxisCount: MediaQuery.sizeOf(context).width < 370 ? 2 : 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1.08,
        children: [
          _v3ModuleTile(
            context,
            Icons.fact_check_outlined,
            'Attendance',
            _sumRows(children, 'attendance'),
            0,
          ),
          _v3ModuleTile(
            context,
            Icons.calendar_month_outlined,
            'Timetable',
            _sumRows(children, 'timetable'),
            0,
          ),
          _v3ModuleTile(
            context,
            Icons.menu_book_outlined,
            'Homework',
            homeworkRows.length,
            0,
          ),
          _v3ModuleTile(
            context,
            Icons.assessment_outlined,
            'Results',
            _sumRows(children, 'results'),
            0,
          ),
          _v3ModuleTile(
            context,
            Icons.payments_outlined,
            'Fees',
            feeRows.length,
            2,
          ),
          _v3ModuleTile(
            context,
            Icons.campaign_outlined,
            'Notices',
            announcementRows.length,
            1,
          ),
        ],
      ),
      if (widget.commands.isNotEmpty) ...[
        _sectionHeading('Recent requests'),
        ...widget.commands.take(3).map(_requestCard),
      ],
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: OutlinedButton.icon(
          onPressed: widget.working ? null : widget.onRefresh,
          icon:
              widget.working
                  ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                  : const Icon(Icons.sync),
          label: Text(
            widget.working ? 'Refreshing…' : 'Refresh school information',
          ),
        ),
      ),
    ];
  }

  Widget _parentV3ChildCard(BuildContext context, Map<String, dynamic> child) {
    final student = _student(child);
    final name =
        student['fullName']?.toString() ??
        student['name']?.toString() ??
        'Linked child';
    final shortName = name.trim().split(RegExp(r'\s+')).first;
    final initials =
        name
            .trim()
            .split(RegExp(r'\s+'))
            .where((part) => part.isNotEmpty)
            .take(2)
            .map((part) => part[0].toUpperCase())
            .join();
    final scheduleOnly = child['accessLevel'] == 'schedule_only';
    final detail = [
      if (student['className'] != null)
        'Class ${student['className']}${student['sectionName'] == null ? '' : ' · ${student['sectionName']}'}',
      if (student['admissionNo'] != null) 'Admission ${student['admissionNo']}',
    ].join('  ·  ');
    return Card(
      margin: const EdgeInsets.only(bottom: 9),
      color: const Color(0xff1d5fa6),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(17)),
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 25,
                  backgroundColor: Colors.white,
                  child: Text(
                    initials.isEmpty ? 'S' : initials,
                    style: const TextStyle(
                      color: Color(0xff1d5fa6),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                      Text(
                        detail.isEmpty
                            ? child['schoolName']?.toString() ?? 'School'
                            : '$detail  ·  ${child['schoolName'] ?? 'School'}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xffe7f0fb),
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: Color(0xffe7f0fb)),
              ],
            ),
            const SizedBox(height: 12),
            if (!scheduleOnly)
              Row(
                children: [
                  _v3Metric('Attendance', _rows(child, 'attendance').length),
                  _v3Metric('Homework', _rows(child, 'homework').length),
                  _v3Metric('Results', _rows(child, 'results').length),
                  _v3Metric('Fees', _rows(child, 'fees').length),
                ],
              )
            else
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Schedule-only access',
                  style: TextStyle(
                    color: Color(0xffe7f0fb),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            const SizedBox(height: 9),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _syncLabel(child['projectedAt']),
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xffe7f0fb),
                    ),
                  ),
                ),
                if (!scheduleOnly)
                  TextButton.icon(
                    onPressed:
                        widget.working
                            ? null
                            : () => _requestLeave(context, child),
                    icon: const Icon(Icons.edit_calendar_outlined, size: 18),
                    label: Text('Request · $shortName'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _v3Metric(String label, int value) => Expanded(
    child: Container(
      margin: const EdgeInsets.only(right: 5),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 3),
      decoration: BoxDecoration(
        color: const Color(0xfff4f7fb),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Text(
            '$value',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: Color(0xff1d5fa6),
            ),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: Color(0xff68778b)),
          ),
        ],
      ),
    ),
  );

  int _sumRows(List<Map<String, dynamic>> children, String key) =>
      children.fold<int>(0, (total, child) {
        if (child['accessLevel'] == 'schedule_only' && key != 'timetable') {
          return total;
        }
        return total + _rows(child, key).length;
      });

  String _attentionSubtitle(Map<String, dynamic> row, String fallback) {
    final parts = <String>[];
    if (row['_student']?.toString().isNotEmpty == true)
      parts.add(row['_student'].toString());
    if (row['_school']?.toString().isNotEmpty == true)
      parts.add(row['_school'].toString());
    if (row['dueOn']?.toString().isNotEmpty == true)
      parts.add('Due ${row['dueOn']}');
    if (row['amount'] != null) parts.add('₹${row['amount']}');
    if (row['status']?.toString().isNotEmpty == true)
      parts.add(row['status'].toString());
    return parts.isEmpty ? fallback : parts.join(' · ');
  }

  Widget _v3AttentionRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required String action,
    required VoidCallback onTap,
  }) => Row(
    children: [
      CircleAvatar(
        radius: 18,
        backgroundColor: const Color(0xffe8f0fa),
        child: Icon(icon, size: 19, color: const Color(0xff1d5fa6)),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: Color(0xff68778b)),
            ),
          ],
        ),
      ),
      TextButton(onPressed: onTap, child: Text(action)),
    ],
  );

  Widget _v3ModuleTile(
    BuildContext context,
    IconData icon,
    String label,
    int count,
    int destination,
  ) => Material(
    color: Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: const BorderSide(color: Color(0xffe3e8ee)),
    ),
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap:
          () => setState(() {
            _selectedIndex = 1;
            _learnSectionIndex = destination;
          }),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: const Color(0xffe8f0fa),
              child: Icon(icon, size: 21, color: const Color(0xff1d5fa6)),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
            Text(
              '$count record${count == 1 ? '' : 's'}',
              style: const TextStyle(fontSize: 10.5, color: Color(0xff68778b)),
            ),
          ],
        ),
      ),
    ),
  );

  List<Widget> _parentV3Learn(BuildContext context) {
    if (widget.children.isEmpty) return _parentV3Home(context);
    return [
      const Text(
        'Learn+',
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 5),
      const Text(
        'School-day information shared for your linked children.',
        style: TextStyle(color: Color(0xff68778b)),
      ),
      const SizedBox(height: 10),
      SegmentedButton<int>(
        segments: const [
          ButtonSegment(
            value: 0,
            icon: Icon(Icons.calendar_today_outlined),
            label: Text('School day'),
          ),
          ButtonSegment(
            value: 1,
            icon: Icon(Icons.inbox_outlined),
            label: Text('Notices'),
          ),
          ButtonSegment(
            value: 2,
            icon: Icon(Icons.payments_outlined),
            label: Text('Fees'),
          ),
        ],
        selected: {_learnSectionIndex},
        onSelectionChanged:
            (selection) => setState(() => _learnSectionIndex = selection.first),
      ),
      const SizedBox(height: 10),
      if (_learnSectionIndex == 0) ..._learningContent(context),
      if (_learnSectionIndex == 1) ..._inboxContent(context),
      if (_learnSectionIndex == 2) ..._paymentsContent(context),
    ];
  }

  List<Widget> _parentV3Shop(BuildContext context) => [
    const Text(
      'Shop',
      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
    ),
    const SizedBox(height: 5),
    const Text(
      'School-approved products and services.',
      style: TextStyle(color: Color(0xff68778b)),
    ),
    const SizedBox(height: 14),
    _v3Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 146,
            width: double.infinity,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xffeef4fb),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.storefront_outlined,
              size: 52,
              color: Color(0xff1d5fa6),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'Your school shop is not connected yet',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          const Text(
            'When your school enables its catalogue, approved uniforms, books and supplies will appear here. No purchases or payments are processed in this app today.',
            style: TextStyle(color: Color(0xff68778b), height: 1.45),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed:
                    () => setState(() {
                      _selectedIndex = 1;
                      _learnSectionIndex = 2;
                    }),
                icon: const Icon(Icons.receipt_long_outlined),
                label: const Text('View school fee records'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => setState(() => _selectedIndex = 3),
                icon: const Icon(Icons.support_agent_outlined),
                label: const Text('Get help'),
              ),
            ],
          ),
        ],
      ),
    ),
  ];

  Widget _v3Card({
    required Widget child,
    EdgeInsets margin = const EdgeInsets.only(bottom: 10),
  }) => Card(
    margin: margin,
    color: Colors.white,
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(15),
      side: const BorderSide(color: Color(0xffe3e8ee)),
    ),
    child: Padding(padding: const EdgeInsets.all(14), child: child),
  );

  List<Widget> _tabContent(BuildContext context) {
    if (widget.children.isEmpty) {
      return [
        Card(
          child: Padding(
            padding: EdgeInsets.all(17),
            child: Text(
              widget.cacheCleared
                  ? 'The saved school information was removed from this phone. Refresh when you want to download it again.'
                  : 'No child is linked to this account yet. Ask the school office to connect your parent account.',
              style: const TextStyle(color: Color(0xff69788d), height: 1.45),
            ),
          ),
        ),
        if (widget.cacheCleared && _selectedIndex == 0)
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonalIcon(
              onPressed: widget.working ? null : widget.onRefresh,
              icon: const Icon(Icons.sync),
              label: const Text('Download school information'),
            ),
          ),
        if (_selectedIndex == 4) ..._exploreContent(context),
      ];
    }

    return switch (_selectedIndex) {
      0 => _homeContent(context),
      1 => _learningContent(context),
      2 => _inboxContent(context),
      3 => _paymentsContent(context),
      _ => _exploreContent(context),
    };
  }

  List<Widget> _homeContent(BuildContext context) => [
    _sectionHeading('Your children'),
    for (final child in widget.children) _homeChildCard(context, child),
    if (widget.commands.isNotEmpty) ...[
      const SizedBox(height: 8),
      _sectionHeading('Recent requests'),
      ...widget.commands.take(3).map(_requestCard),
    ],
    Align(
      alignment: Alignment.centerRight,
      child: TextButton.icon(
        onPressed: widget.working ? null : widget.onRefresh,
        icon: const Icon(Icons.sync),
        label: const Text('Refresh school information'),
      ),
    ),
  ];

  Widget _homeChildCard(BuildContext context, Map<String, dynamic> child) {
    final student = _student(child);
    final scheduleOnly = child['accessLevel'] == 'schedule_only';
    final attendance = _rows(child, 'attendance');
    final homework = _rows(child, 'homework');
    final results = _rows(child, 'results');
    final fees = _rows(child, 'fees');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap:
                  () => setState(() {
                    _selectedChildId = child['studentPublicId']?.toString();
                    _selectedIndex = 1;
                  }),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      student['fullName']?.toString() ?? 'Linked child',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${child['schoolName'] ?? 'School'} · ${student['className'] ?? ''} ${student['sectionName'] ?? ''}',
                      style: const TextStyle(color: Color(0xff68778b)),
                    ),
                    if (scheduleOnly) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'Schedule-only access · timetable details only',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xff476eaa),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    if (!scheduleOnly)
                      Wrap(
                        spacing: 7,
                        runSpacing: 7,
                        children: [
                          _ParentCount(
                            label: 'Attendance',
                            count: attendance.length,
                          ),
                          _ParentCount(
                            label: 'Homework',
                            count: homework.length,
                          ),
                          _ParentCount(label: 'Results', count: results.length),
                          _ParentCount(
                            label: 'Fee records',
                            count: fees.length,
                          ),
                        ],
                      ),
                    const SizedBox(height: 8),
                    Text(
                      _syncLabel(child['projectedAt']),
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xff68778b),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (!scheduleOnly)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed:
                      widget.working
                          ? null
                          : () => _requestLeave(context, child),
                  icon: const Icon(Icons.edit_calendar_outlined),
                  label: const Text('Request leave'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _learningContent(BuildContext context) => [
    ..._familyCalendarSection(),
    const SizedBox(height: 8),
    const Text('Timetable view', style: TextStyle(fontWeight: FontWeight.w700)),
    const SizedBox(height: 6),
    SegmentedButton<bool>(
      segments: const [
        ButtonSegment<bool>(value: false, label: Text('Today')),
        ButtonSegment<bool>(value: true, label: Text('Week')),
      ],
      selected: {_showWeeklyTimetable},
      onSelectionChanged:
          (selection) => setState(() => _showWeeklyTimetable = selection.first),
    ),
    for (final child in _visibleChildren) ...[
      _childHeading(child),
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          'School schedule · ${_syncLabel(child['projectedAt'])}',
          style: const TextStyle(fontSize: 12, color: Color(0xff68778b)),
        ),
      ),
      if (child['accessLevel'] != 'schedule_only')
        ..._parentAttendanceSection(child),
      ..._recordSection(
        context,
        'Timetable',
        _visibleTimetable(child),
        (row) =>
            '${row['startTime'] ?? '—'}–${row['endTime'] ?? '—'} · ${row['subjectName'] ?? 'Class'}',
        (row) =>
            '${row['className'] ?? ''} ${row['sectionName'] ?? ''} · ${row['teacherName'] ?? 'Teacher not assigned'} · ${row['room'] ?? 'Room not set'}',
        action: (row) => SchoolMeetingLinkButton(link: row['meetingLink']),
      ),
      if (child['accessLevel'] != 'schedule_only') ...[
        ..._recordSection(
          context,
          'Homework',
          _rows(child, 'homework'),
          (row) => row['title']?.toString() ?? 'Homework',
          (row) =>
              '${row['subjectName'] ?? 'Classwork'} · Due ${row['dueOn'] ?? 'not set'}',
          detail: (row) => row['details']?.toString() ?? '',
        ),
        ..._recordSection(
          context,
          'Published results',
          _rows(child, 'results'),
          (row) =>
              '${row['examTitle'] ?? 'Exam'} · ${row['subjectName'] ?? ''}',
          (row) =>
              '${row['marksAwarded'] ?? '—'} / ${row['maxMarks'] ?? '—'} · ${row['examDate'] ?? ''}',
        ),
      ],
    ],
  ];

  List<Widget> _parentAttendanceSection(Map<String, dynamic> child) {
    final attendance = _rows(child, 'attendance')..sort((a, b) {
      final dateOrder = (b['date']?.toString() ?? '').compareTo(
        a['date']?.toString() ?? '',
      );
      if (dateOrder != 0) return dateOrder;
      final aPeriod = int.tryParse(a['period']?.toString() ?? '') ?? 0;
      final bPeriod = int.tryParse(b['period']?.toString() ?? '') ?? 0;
      return aPeriod.compareTo(bPeriod);
    });
    final range = _attendanceDateRange;
    final filtered =
        attendance.where((row) {
          if (range == null) return true;
          final date = DateTime.tryParse(row['date']?.toString() ?? '');
          if (date == null) return false;
          final day = DateTime(date.year, date.month, date.day);
          final start = DateTime(
            range.start.year,
            range.start.month,
            range.start.day,
          );
          final end = DateTime(range.end.year, range.end.month, range.end.day);
          return !day.isBefore(start) && !day.isAfter(end);
        }).toList();
    final rangeLabel =
        range == null
            ? 'All available dates'
            : '${_attendanceDateLabel(range.start)} – ${_attendanceDateLabel(range.end)}';
    return [
      const SizedBox(height: 8),
      _sectionHeading('Attendance'),
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 4,
        children: [
          Text(rangeLabel, style: const TextStyle(color: Color(0xff68778b))),
          TextButton.icon(
            onPressed: () async {
              final today = DateTime.now();
              final selected = await showDateRangePicker(
                context: context,
                firstDate: DateTime(2000),
                lastDate: today,
                initialDateRange: range,
              );
              if (selected != null && mounted) {
                setState(() => _attendanceDateRange = selected);
              }
            },
            icon: const Icon(Icons.date_range_outlined),
            label: const Text('Filter dates'),
          ),
          if (range != null)
            TextButton(
              onPressed: () => setState(() => _attendanceDateRange = null),
              child: const Text('Clear'),
            ),
        ],
      ),
      if (filtered.isEmpty)
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            'No attendance records in this date range.',
            style: TextStyle(color: Color(0xff68778b)),
          ),
        )
      else
        ...filtered.map(
          (row) => Card(
            child: ListTile(
              leading: const Icon(Icons.fact_check_outlined),
              title: Text(
                _attendanceDateLabel(
                  DateTime.tryParse(row['date']?.toString() ?? ''),
                ),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Status: ${_attendanceStatusLabel(row['statusLabel']?.toString().isNotEmpty == true ? row['statusLabel'].toString() : row['status']?.toString() ?? '')}'
                    ' · ${_attendanceSessionLabel(row['period'])}',
                  ),
                  if (row['updatedAt'] != null)
                    Text(
                      _syncLabel(row['updatedAt']),
                      style: const TextStyle(fontSize: 11),
                    ),
                ],
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap:
                  () => _showRecordDetail(
                    context,
                    'Attendance',
                    [
                      'Date: ${_attendanceDateLabel(DateTime.tryParse(row['date']?.toString() ?? ''))}',
                      'Status: ${_attendanceStatusLabel(row['statusLabel']?.toString().isNotEmpty == true ? row['statusLabel'].toString() : row['status']?.toString() ?? '')}',
                      'Session: ${_attendanceSessionLabel(row['period'])}',
                      if (row['reason']?.toString().isNotEmpty == true)
                        'Note: ${row['reason']}',
                      if (row['updatedAt'] != null)
                        _syncLabel(row['updatedAt']),
                      'Shared by the school; this view does not change attendance.',
                    ].join('\n\n'),
                  ),
            ),
          ),
        ),
    ];
  }

  String _attendanceDateLabel(DateTime? date) {
    if (date == null) return 'Date unavailable';
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
  }

  String _attendanceStatusLabel(String status) => switch (status) {
    'present' => 'Present',
    'absent' => 'Absent',
    'late' => 'Late',
    'excused' => 'Excused',
    'early_departure' => 'Left early',
    _ => status.isEmpty ? 'Unknown' : status,
  };

  String _attendanceSessionLabel(Object? value) {
    final period = int.tryParse(value?.toString() ?? '') ?? 0;
    return period == 0 ? 'Full day' : 'Period $period';
  }

  List<Widget> _inboxContent(BuildContext context) => [
    for (final child in _visibleChildren.where(
      (child) => child['accessLevel'] != 'schedule_only',
    )) ...[
      _childHeading(child),
      ..._recordSection(
        context,
        'School notices',
        _rows(child, 'announcements'),
        (row) => row['title']?.toString() ?? 'School notice',
        (row) => row['publishOn']?.toString() ?? '',
        detail: (row) => row['message']?.toString() ?? '',
      ),
    ],
    if (widget.commands.isNotEmpty) ...[
      const SizedBox(height: 12),
      _sectionHeading('Your requests'),
      ...widget.commands.map(_requestCard),
    ],
  ];

  List<Widget> _paymentsContent(BuildContext context) => [
    const _InfoBanner(
      text:
          'These are school fee records. The school is the payee; contact the school office about fee balances or reconciliation.',
    ),
    for (final child in _visibleChildren.where(
      (child) => child['accessLevel'] != 'schedule_only',
    )) ...[
      _childHeading(child),
      ..._recordSection(
        context,
        'Fee records',
        _rows(child, 'fees'),
        (row) =>
            row['feeName']?.toString() ?? row['period']?.toString() ?? 'Fee',
        (row) => [
          if (row['amount'] != null) 'Amount ₹${row['amount']}',
          if (row['paidAmount'] != null) 'Paid ₹${row['paidAmount']}',
          if (row['status'] != null) row['status'].toString(),
          if (row['dueOn'] != null) 'Due ${row['dueOn']}',
        ].join(' · '),
      ),
    ],
  ];

  List<Widget> _exploreContent(BuildContext context) => [
    const Text(
      'Settings',
      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
    ),
    const SizedBox(height: 5),
    Text(
      widget.user['email']?.toString() ?? 'Parent account',
      style: const TextStyle(color: Color(0xff68778b)),
    ),
    const SizedBox(height: 8),
    _ActiveSessionsButton(api: widget.api, onSignOut: widget.onSignOut),
    _sectionHeading('Account and preferences'),
    Text('Text size · ${(widget.textScale * 100).round()}%'),
    Slider.adaptive(
      min: 0.85,
      max: 1.5,
      divisions: 13,
      value: widget.textScale.clamp(0.85, 1.5),
      label: '${(widget.textScale * 100).round()}%',
      semanticFormatterCallback: (value) => '${(value * 100).round()} percent',
      onChanged: widget.onTextScaleChanged,
    ),
    SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      title: const Text('Use phone biometrics'),
      subtitle: const Text(
        'Unlock this saved session on this phone. The server still checks school access.',
      ),
      value: widget.biometricEnabled,
      onChanged: widget.onBiometricChanged,
    ),
    _PrimaryButton(
      label: 'Enable notifications',
      working: widget.working,
      icon: Icons.notifications_active_outlined,
      onPressed: widget.onEnableNotifications,
    ),
    const SizedBox(height: 8),
    const Text(
      'Choose which school updates may send a push alert. School records remain available in the app.',
      style: TextStyle(fontSize: 13, color: Color(0xff6c7a8e)),
    ),
    SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      title: const Text('School announcements'),
      value: widget.notificationPreferences['school_notice'] ?? true,
      onChanged:
          widget.working
              ? null
              : (enabled) => widget.onNotificationPreferenceChanged(
                'school_notice',
                enabled,
              ),
    ),
    SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      title: const Text('Timetable and calendar updates'),
      value: widget.notificationPreferences['schedule_update'] ?? true,
      onChanged:
          widget.working
              ? null
              : (enabled) => widget.onNotificationPreferenceChanged(
                'schedule_update',
                enabled,
              ),
    ),
    SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      title: const Text('New homework'),
      value: widget.notificationPreferences['homework_update'] ?? true,
      onChanged:
          widget.working
              ? null
              : (enabled) => widget.onNotificationPreferenceChanged(
                'homework_update',
                enabled,
              ),
    ),
    const SizedBox(height: 8),
    _ConsentRow(
      value: widget.analyticsConsent,
      onChanged: widget.onConsentChanged,
    ),
    Card(
      margin: const EdgeInsets.only(top: 4, bottom: 10),
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(15),
        side: const BorderSide(color: Color(0xffe3e8ee)),
      ),
      child: ExpansionTile(
        leading: const Icon(Icons.cloud_outlined, color: Color(0xff1d5fa6)),
        title: const Text(
          'Firebase services',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          widget.analyticsConsent && FirebaseServices.ready
              ? 'Optional diagnostics are enabled'
              : 'Optional diagnostics are off',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        children: [
          _serviceStatus(
            'Google sign-in',
            'Used to verify your parent account',
            true,
          ),
          _serviceStatus(
            'FCM notifications',
            'Firebase Messaging is available; phone permission is still required',
            FirebaseServices.ready,
            state: FirebaseServices.ready ? 'Ready' : 'Unavailable',
          ),
          _serviceStatus(
            'Analytics',
            'Anonymous app usage events',
            widget.analyticsConsent && FirebaseServices.ready,
          ),
          _serviceStatus(
            'Crashlytics',
            'Crash reports for diagnosing app failures',
            widget.analyticsConsent && FirebaseServices.ready,
          ),
          _serviceStatus(
            'Performance Monitoring',
            'App and school-server response timings',
            widget.analyticsConsent && FirebaseServices.ready,
          ),
          _serviceStatus(
            'In-App Messaging',
            'Optional messages inside the app',
            widget.analyticsConsent && FirebaseServices.ready,
          ),
          _serviceStatus(
            'Remote Config',
            'Optional app settings fetched after diagnostics consent',
            widget.analyticsConsent && FirebaseServices.ready,
          ),
          _serviceStatus(
            'App Check',
            'Not configured in this app build',
            false,
            state: 'Not configured',
          ),
          _serviceStatus(
            'Firestore / Realtime Database / Hosting / AI Logic',
            'Not used by the Parents app in this build',
            false,
            state: 'Not used',
          ),
          const SizedBox(height: 6),
          const Text(
            'Turning diagnostics off disables collection for Analytics, Crashlytics, Performance Monitoring and In-App Messaging. School records and sign-in continue to work.',
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: Color(0xff68778b),
            ),
          ),
        ],
      ),
    ),
    ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.privacy_tip_outlined),
      title: const Text('Privacy and data'),
      subtitle: const Text('How school records, backups and diagnostics work'),
      trailing: const Icon(Icons.chevron_right),
      onTap:
          () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder:
                  (_) => _ParentPrivacyPage(
                    diagnosticsEnabled: widget.analyticsConsent,
                  ),
            ),
          ),
    ),
    ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.delete_outline),
      title: const Text('Remove saved school information'),
      subtitle: const Text(
        'Remove the offline copy from this phone. School records and queued requests stay unchanged.',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: widget.working ? null : () => _confirmClearCache(context),
    ),
    const SizedBox(height: 10),
    _sectionHeading('Help and support'),
    const Text(
      'Send a request to the School ERP operator about account access, child links, records, fees, backups, ads or purchases. The operator can route it to your school or platform team. Follow its status here.',
      style: TextStyle(fontSize: 13, color: Color(0xff6c7a8e), height: 1.4),
    ),
    const SizedBox(height: 8),
    if (!widget.supportAvailable)
      const Card(
        child: Padding(
          padding: EdgeInsets.all(14),
          child: Text(
            'Support requests are not available on this server yet. Contact your school office directly.',
          ),
        ),
      )
    else if (widget.isOffline)
      const Card(
        child: Padding(
          padding: EdgeInsets.all(14),
          child: Text(
            'Support requests need an internet connection. Reconnect to view or submit a request.',
          ),
        ),
      )
    else
      FilledButton.icon(
        onPressed: widget.working ? null : () => _openSupportTicket(context),
        icon: const Icon(Icons.support_agent_outlined),
        label: const Text('Contact support'),
      ),
    if (widget.supportAvailable && !widget.isOffline) ...[
      Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: widget.working ? null : widget.onRefresh,
          icon: const Icon(Icons.refresh),
          label: const Text('Refresh support requests'),
        ),
      ),
      if (widget.supportTickets.isEmpty)
        const Card(
          child: Padding(
            padding: EdgeInsets.all(14),
            child: Text('Your support requests will appear here.'),
          ),
        ),
      ...widget.supportTickets.map(_supportTicketCard),
    ],
    const SizedBox(height: 12),
    TextButton(
      onPressed: widget.onChangeServer,
      child: const Text('Change school server'),
    ),
    TextButton(onPressed: widget.onSignOut, child: const Text('Sign out')),
  ];

  Widget _serviceStatus(
    String name,
    String detail,
    bool enabled, {
    String? state,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          enabled ? Icons.check_circle_outline : Icons.remove_circle_outline,
          size: 18,
          color: enabled ? const Color(0xff24804a) : const Color(0xff8994a3),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                ),
              ),
              Text(
                detail,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: Color(0xff68778b),
                ),
              ),
            ],
          ),
        ),
        Text(
          state ?? (enabled ? 'On' : 'Off'),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: enabled ? const Color(0xff24804a) : const Color(0xff68778b),
          ),
        ),
      ],
    ),
  );

  Widget _sectionHeading(String title) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 6),
    child: Text(
      title,
      style: const TextStyle(
        color: Color(0xff122238),
        fontSize: 16,
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  Widget _childHeading(Map<String, dynamic> child) {
    final student = _student(child);
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Text(
        '${student['fullName'] ?? 'Child'} · ${child['schoolName'] ?? 'School'}',
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    );
  }

  List<Widget> _recordSection(
    BuildContext context,
    String title,
    List<Map<String, dynamic>> rows,
    String Function(Map<String, dynamic>) titleOf,
    String Function(Map<String, dynamic>) subtitleOf, {
    String Function(Map<String, dynamic>)? detail,
    Widget Function(Map<String, dynamic>)? action,
  }) => [
    const SizedBox(height: 8),
    _sectionHeading(title),
    if (rows.isEmpty)
      const Padding(
        padding: EdgeInsets.only(bottom: 8),
        child: Text(
          'No published information yet.',
          style: TextStyle(color: Color(0xff68778b)),
        ),
      ),
    ...rows.map(
      (row) => Card(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(titleOf(row)),
              subtitle: Text(subtitleOf(row)),
              trailing: const Icon(Icons.chevron_right),
              onTap:
                  () => _showRecordDetail(
                    context,
                    titleOf(row),
                    [
                      subtitleOf(row),
                      if ((detail?.call(row) ?? '').isNotEmpty) detail!(row),
                    ].where((value) => value.isNotEmpty).join('\n\n'),
                  ),
            ),
            if (action != null) action(row),
          ],
        ),
      ),
    ),
  ];

  Widget _requestCard(Map<String, dynamic> command) {
    final status = command['status']?.toString() ?? 'queued';
    final (label, icon) = switch (status) {
      'queued' ||
      'delivered' => ('Waiting for school sync', Icons.sync_outlined),
      'accepted' => ('Received · awaiting school review', Icons.hourglass_top),
      'request_approved' => (
        'Approved by the school',
        Icons.check_circle_outline,
      ),
      'request_rejected' => ('Declined by the school', Icons.cancel_outlined),
      'needs_info' => ('The school needs more information', Icons.help_outline),
      'rejected' => ('Could not deliver to the school', Icons.error_outline),
      _ => ('Status unavailable', Icons.help_outline),
    };
    final message = command['message']?.toString() ?? '';
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(label),
        subtitle: Text(
          [
            if (message.isNotEmpty && status != 'accepted') message,
            'Request ${command['operationId'] ?? ''}',
          ].join(' · '),
        ),
      ),
    );
  }

  Widget _supportTicketCard(Map<String, dynamic> ticket) {
    final status = ticket['status']?.toString() ?? 'unknown';
    final statusLabel = switch (status) {
      'open' => 'Open',
      'in_progress' => 'In progress',
      'waiting_on_parent' => 'Waiting for you',
      'escalated' => 'Escalated',
      'resolved' => 'Resolved',
      'closed' => 'Closed',
      _ => 'Status unavailable',
    };
    final response = ticket['response']?.toString().trim() ?? '';
    final school = ticket['schoolName']?.toString() ?? 'School support';
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.confirmation_number_outlined),
              title: Text(ticket['subject']?.toString() ?? 'Support request'),
              subtitle: Text(
                '${ticket['reference'] ?? 'Reference unavailable'} · $statusLabel · ${ticket['escalationTarget'] == 'school' ? school : 'Platform support'}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap:
                  () => _showRecordDetail(
                    context,
                    ticket['reference']?.toString() ?? 'Support request',
                    [
                      ticket['subject']?.toString() ?? '',
                      'Status: $statusLabel',
                      'Sent to: ${ticket['escalationTarget'] == 'school' ? school : 'Platform support'}',
                      ticket['message']?.toString() ?? '',
                      if (response.isNotEmpty) 'Response:\n$response',
                    ].where((line) => line.isNotEmpty).join('\n\n'),
                  ),
            ),
            if (response.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Latest response: $response',
                    style: const TextStyle(color: Color(0xff52647b)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openSupportTicket(BuildContext context) async {
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _ParentSupportTicketDialog(children: widget.children),
    );
    if (values != null) await widget.onSubmitSupportTicket(values);
  }

  Future<void> _confirmClearCache(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Remove saved school information?'),
            content: const Text(
              'This removes the offline copy from this phone. It does not delete school records, change your account, or cancel requests still waiting to sync. You can download the information again after reconnecting.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Keep it'),
              ),
              FilledButton.tonal(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Remove from this phone'),
              ),
            ],
          ),
    );
    if (confirmed == true) await widget.onClearCache();
  }

  Future<void> _requestLeave(
    BuildContext context,
    Map<String, dynamic> child,
  ) async {
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => const _HostedParentRequestDialog(),
    );
    if (values == null) return;
    widget.onSubmitRequest({
      ...values,
      'studentPublicId': child['studentPublicId']?.toString() ?? '',
    });
  }

  Future<void> _showRecordDetail(
    BuildContext context,
    String title,
    String details,
  ) => showDialog<void>(
    context: context,
    builder:
        (dialogContext) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(details)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
          ],
        ),
  );

  String _formatSyncTime(Object? value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '');
    if (parsed == null) return 'time unavailable';
    final local = parsed.toLocal();
    final date = '${local.day}/${local.month}/${local.year}';
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    return '$date at $hour:$minute ${local.hour >= 12 ? 'PM' : 'AM'}';
  }

  String _syncLabel(Object? value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '');
    if (parsed == null) return 'Last sync time unavailable';
    final age = DateTime.now().toUtc().difference(parsed.toUtc());
    final stale = age > const Duration(hours: 24);
    return '${stale ? 'Stale · ' : 'Updated '}${_formatSyncTime(value)}';
  }
}

class _ParentPrivacyPage extends StatelessWidget {
  const _ParentPrivacyPage({required this.diagnosticsEnabled});

  final bool diagnosticsEnabled;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Privacy and data')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'What this app does today',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        const Text(
          'These notes describe the current Parent app. Your school also '
          'sets its own rules for student records.',
        ),
        const SizedBox(height: 12),
        const _ParentPrivacySection(
          title: 'School records',
          body:
              'The school controls which children are linked to your account. '
              'The app requests records for linked children from the school '
              'Hub or its hosted service. It keeps the latest downloaded '
              'records on this phone so you can read them offline. The local '
              'cache is not encrypted by this app; protect the phone with its '
              'screen lock and sign out on a device you no longer use.',
        ),
        const _ParentPrivacySection(
          title: 'Google Drive backups',
          body:
              'This Parent app does not currently upload its records or '
              'offline cache to Google Drive. Drive backup and restore are '
              'not available in this version.',
        ),
        const _ParentPrivacySection(
          title: 'Advertising',
          body:
              'This version does not display ads or include an advertising '
              'SDK. School announcements and records are not ad placements.',
        ),
        const _ParentPrivacySection(
          title: 'Fees and app purchases',
          body:
              'The app can show fee records entered by the school, but it '
              'does not collect school-fee payments. In-app subscriptions '
              'and course purchases are not available in this version.',
        ),
        const _ParentPrivacySection(
          title: 'Request access, correction or deletion',
          body:
              'Open Requests, choose the linked child and submit a data access, '
              'correction or deletion request. You can follow its status in the '
              'app. Sending or approving a request does not automatically change '
              'or erase school records; the school must review it and follow its '
              'record-retention rules.',
        ),
        _ParentPrivacySection(
          title: 'Optional diagnostics',
          body:
              'Analytics, crash reports, performance monitoring and '
              'in-app messages are ${diagnosticsEnabled ? 'enabled because you opted in' : 'off because you have not opted in'}. '
              'You can change this choice in Explore.',
        ),
      ],
    ),
  );
}

class _ParentPrivacySection extends StatelessWidget {
  const _ParentPrivacySection({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(top: 8),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
          const SizedBox(height: 6),
          Text(body, style: const TextStyle(height: 1.45)),
        ],
      ),
    ),
  );
}

class _ParentCount extends StatelessWidget {
  const _ParentCount({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) => Chip(
    label: Text('$label  $count', style: const TextStyle(fontSize: 11)),
    visualDensity: VisualDensity.compact,
    backgroundColor: const Color(0xffedf3ff),
  );
}

class _ParentSupportTicketDialog extends StatefulWidget {
  const _ParentSupportTicketDialog({required this.children});

  final List<Map<String, dynamic>> children;

  @override
  State<_ParentSupportTicketDialog> createState() =>
      _ParentSupportTicketDialogState();
}

class _ParentSupportTicketDialogState
    extends State<_ParentSupportTicketDialog> {
  final _formKey = GlobalKey<FormState>();
  final _subject = TextEditingController();
  final _message = TextEditingController();
  String _category = 'technical_issue';
  String? _studentPublicId;

  static const _categories = <(String, String)>[
    ('login_access', 'Login or account access'),
    ('child_linking', 'Linking a child'),
    ('record_visibility', 'School records'),
    ('school_fees', 'School fees'),
    ('platform_payments', 'Platform payments'),
    ('backup_restore', 'Backup or restore'),
    ('ads', 'Advertisements'),
    ('purchases', 'Purchases'),
    ('technical_issue', 'Technical issue'),
    ('other', 'Other'),
  ];

  Map<String, dynamic> _student(Map<String, dynamic> child) =>
      Map<String, dynamic>.from(
        (Map<String, dynamic>.from(child['snapshot'] as Map? ?? {}))['student']
                as Map? ??
            {},
      );

  @override
  void dispose() {
    _subject.dispose();
    _message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Contact support'),
    content: SizedBox(
      width: 460,
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: _category,
                decoration: const InputDecoration(
                  labelText: 'What do you need help with?',
                ),
                items: [
                  for (final (value, label) in _categories)
                    DropdownMenuItem(value: value, child: Text(label)),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _category = value);
                },
              ),
              if (widget.children.isNotEmpty) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String?>(
                  initialValue: _studentPublicId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'About a child (optional)',
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Not about a specific child'),
                    ),
                    ...widget.children.map((child) {
                      final student = _student(child);
                      return DropdownMenuItem<String?>(
                        value: child['studentPublicId']?.toString(),
                        child: Text(
                          '${student['fullName'] ?? 'Child'} · ${child['schoolName'] ?? 'School'}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    }),
                  ],
                  onChanged:
                      (value) => setState(() => _studentPublicId = value),
                ),
              ],
              const SizedBox(height: 8),
              TextFormField(
                controller: _subject,
                maxLength: 160,
                decoration: const InputDecoration(labelText: 'Subject'),
                validator: (value) {
                  if ((value?.trim().length ?? 0) < 4) {
                    return 'Enter at least 4 characters.';
                  }
                  return null;
                },
              ),
              TextFormField(
                controller: _message,
                minLines: 4,
                maxLines: 7,
                maxLength: 3000,
                decoration: const InputDecoration(
                  labelText: 'How can we help?',
                  alignLabelWithHint: true,
                ),
                validator: (value) {
                  if ((value?.trim().length ?? 0) < 10) {
                    return 'Please add a little more detail (at least 10 characters).';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 6),
              const Text(
                'Do not include passwords, sign-in codes, payment card details or highly sensitive student information.',
                style: TextStyle(fontSize: 12, color: Color(0xff6c7a8e)),
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton.icon(
        onPressed: () {
          if (!(_formKey.currentState?.validate() ?? false)) return;
          Navigator.pop(context, {
            'category': _category,
            'subject': _subject.text.trim(),
            'message': _message.text.trim(),
            if (_studentPublicId != null) 'studentPublicId': _studentPublicId!,
          });
        },
        icon: const Icon(Icons.send_outlined),
        label: const Text('Submit request'),
      ),
    ],
  );
}

class _HostedParentRequestDialog extends StatefulWidget {
  const _HostedParentRequestDialog();

  @override
  State<_HostedParentRequestDialog> createState() =>
      _HostedParentRequestDialogState();
}

class _HostedParentRequestDialogState
    extends State<_HostedParentRequestDialog> {
  final _formKey = GlobalKey<FormState>();
  final _message = TextEditingController();
  final _startsOn = TextEditingController();
  final _endsOn = TextEditingController();
  String _requestType = 'leave';

  Future<void> _pickDate(
    TextEditingController controller, {
    DateTime? firstDate,
    DateTime? lastDate,
  }) async {
    final today = DateUtils.dateOnly(DateTime.now());
    final minimum = firstDate ?? DateTime(2000);
    final existing = DateTime.tryParse(controller.text);
    final initial =
        existing != null && !existing.isBefore(minimum)
            ? existing
            : (today.isBefore(minimum) ? minimum : today);
    final selected = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: minimum,
      lastDate: lastDate ?? DateTime(today.year + 3, 12, 31),
    );
    if (selected != null && mounted) {
      controller.text = selected.toIso8601String().substring(0, 10);
      setState(() {});
    }
  }

  @override
  void dispose() {
    _message.dispose();
    _startsOn.dispose();
    _endsOn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Send a request to school'),
    content: Form(
      key: _formKey,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _requestType,
              decoration: const InputDecoration(labelText: 'Request type'),
              items: const [
                DropdownMenuItem(value: 'leave', child: Text('Leave')),
                DropdownMenuItem(
                  value: 'profile_change',
                  child: Text('Profile change'),
                ),
                DropdownMenuItem(value: 'document', child: Text('Document')),
                DropdownMenuItem(
                  value: 'data_access',
                  child: Text('Access my child’s data'),
                ),
                DropdownMenuItem(
                  value: 'data_correction',
                  child: Text('Correct my child’s data'),
                ),
                DropdownMenuItem(
                  value: 'data_deletion',
                  child: Text('Delete my child’s data'),
                ),
                DropdownMenuItem(
                  value: 'attendance_correction',
                  child: Text('Report an attendance mistake'),
                ),
                DropdownMenuItem(value: 'other', child: Text('Other')),
              ],
              onChanged:
                  (value) => setState(() => _requestType = value ?? 'leave'),
            ),
            if (_requestType.startsWith('data_'))
              const _InfoBanner(
                text:
                    'This is sent to the school for review. It does not automatically change or delete records. The school must check its record-retention rules before acting.',
              ),
            if (_requestType == 'attendance_correction')
              const _InfoBanner(
                text:
                    'The school will review this child’s attendance for the selected date. This request does not change the official record automatically.',
              ),
            if (_requestType == 'leave') ...[
              TextFormField(
                controller: _startsOn,
                readOnly: true,
                onTap: () => _pickDate(_startsOn),
                decoration: const InputDecoration(
                  labelText: 'Start date (optional)',
                  hintText: 'Choose a date',
                  suffixIcon: Icon(Icons.calendar_today_outlined),
                ),
                key: const ValueKey('parent-request-start-date'),
                onTapOutside:
                    (_) => FocusManager.instance.primaryFocus?.unfocus(),
                validator:
                    (value) =>
                        validateOptionalIsoDate(value, label: 'start date'),
              ),
              TextFormField(
                controller: _endsOn,
                readOnly: true,
                onTap:
                    () => _pickDate(
                      _endsOn,
                      firstDate:
                          DateTime.tryParse(_startsOn.text) ?? DateTime(2000),
                    ),
                decoration: const InputDecoration(
                  labelText: 'End date (optional)',
                  hintText: 'Choose a date',
                  suffixIcon: Icon(Icons.calendar_today_outlined),
                ),
                key: const ValueKey('parent-request-end-date'),
                validator:
                    (value) =>
                        validateOptionalIsoDate(value, label: 'end date') ??
                        validateOptionalRequestDateRange(
                          startsOn: _startsOn.text,
                          endsOn: value,
                        ),
              ),
            ] else if (_requestType == 'attendance_correction') ...[
              TextFormField(
                controller: _startsOn,
                readOnly: true,
                onTap:
                    () => _pickDate(
                      _startsOn,
                      lastDate: DateUtils.dateOnly(DateTime.now()),
                    ),
                decoration: const InputDecoration(
                  labelText: 'Attendance date',
                  hintText: 'Choose the date to review',
                  suffixIcon: Icon(Icons.calendar_today_outlined),
                ),
                key: const ValueKey('parent-attendance-correction-date'),
                validator: validateAttendanceCorrectionDate,
              ),
            ],
            TextFormField(
              controller: _message,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                labelText:
                    _requestType.startsWith('data_')
                        ? 'Details for the school'
                        : 'Message',
              ),
              validator:
                  (value) =>
                      (value?.trim().length ?? 0) < 3
                          ? 'Enter at least 3 characters.'
                          : null,
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (_formKey.currentState?.validate() != true) return;
          Navigator.pop(context, {
            'requestType': _requestType,
            'startsOn': _startsOn.text.trim(),
            'endsOn': _endsOn.text.trim(),
            'message': _message.text.trim(),
          });
        },
        child: const Text('Submit'),
      ),
    ],
  );
}

IconData _iconFor(String area) {
  if (area.toLowerCase().contains('attendance'))
    return Icons.fact_check_outlined;
  if (area.toLowerCase().contains('message')) return Icons.chat_bubble_outline;
  return Icons.school_outlined;
}

String _parentRequestTypeLabel(Object? value) => switch (value?.toString()) {
  'leave' => 'Leave request',
  'profile_change' => 'Profile change',
  'document' => 'Document request',
  'data_access' => 'Data access request',
  'data_correction' => 'Data correction request',
  'data_deletion' => 'Data deletion request',
  'attendance_correction' => 'Attendance correction request',
  'other' => 'Other request',
  _ => value?.toString().replaceAll('_', ' ') ?? 'Request',
};

class _BiometricUnlockView extends StatelessWidget {
  const _BiometricUnlockView({
    required this.working,
    required this.onUnlock,
    required this.onUsePassword,
    this.error,
  });

  final bool working;
  final String? error;
  final VoidCallback onUnlock;
  final VoidCallback onUsePassword;

  @override
  Widget build(BuildContext context) => _Page(
    role: MobileRole.parent,
    child: _CardBody(
      title: 'Unlock Parent app',
      subtitle:
          'Confirm with this phone’s biometrics to reopen the saved session.',
      error: error,
      children: [
        _PrimaryButton(
          label: 'Unlock with biometrics',
          working: working,
          icon: Icons.fingerprint,
          onPressed: onUnlock,
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: working ? null : onUsePassword,
          child: const Text('Use password sign-in instead'),
        ),
        const Text(
          'Biometrics unlock this phone only. Your school still checks account access with its server.',
          style: TextStyle(color: Color(0xff6b788a), fontSize: 12.5),
        ),
      ],
    ),
  );
}

class _GateView extends StatefulWidget {
  const _GateView({
    required this.role,
    required this.reason,
    this.googleEmail,
    this.error,
    this.success,
    required this.working,
    required this.onAttachGoogle,
    required this.onActivate,
    required this.onRefresh,
    required this.onChangeServer,
  });
  final MobileRole role;
  final String reason;
  final String? googleEmail;
  final String? error;
  final String? success;
  final bool working;
  final VoidCallback onAttachGoogle;
  final ValueChanged<String> onActivate;
  final VoidCallback onRefresh;
  final VoidCallback onChangeServer;

  @override
  State<_GateView> createState() => _GateViewState();
}

class _GateViewState extends State<_GateView> {
  final _activationCode = TextEditingController();

  @override
  void dispose() {
    _activationCode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _Page(
    role: widget.role,
    child: _CardBody(
      title: 'Access is not active yet',
      subtitle: widget.reason,
      error: widget.error,
      success: widget.success,
      children: [
        const _InfoBanner(
          text:
              'The initial trial bypass has ended. Verify the original Google account and enter a valid server activation code to restore access.',
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: widget.working ? null : widget.onAttachGoogle,
          icon: const Icon(Icons.account_circle_outlined),
          label: Text(widget.googleEmail ?? 'Attach original Google account'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _activationCode,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Server activation code',
          ),
        ),
        const SizedBox(height: 14),
        _PrimaryButton(
          label: 'Verify and activate',
          working: widget.working,
          onPressed: () => widget.onActivate(_activationCode.text),
        ),
        TextButton(
          onPressed: widget.working ? null : widget.onRefresh,
          child: const Text('Check setup again'),
        ),
        TextButton(
          onPressed: widget.onChangeServer,
          child: const Text('Use another server'),
        ),
      ],
    ),
  );
}

class _TrialBanner extends StatelessWidget {
  const _TrialBanner({required this.enabled});
  final bool enabled;

  @override
  Widget build(BuildContext context) => _InfoBanner(
    text:
        enabled
            ? 'Trial mode is active. Google account and activation checks are bypassed for now.'
            : 'Trial mode is off. Verified Google sign-in and a valid server activation code are required before setup can finish.',
  );
}

class _ConsentRow extends StatelessWidget {
  const _ConsentRow({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile.adaptive(
    contentPadding: EdgeInsets.zero,
    value: value,
    onChanged: onChanged,
    title: const Text(
      'Share app diagnostics and usage analytics',
      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    ),
    subtitle: const Text(
      'Optional. Enables Firebase Analytics, Crashlytics, Performance '
      'Monitoring and In-App Messaging. Student names, school records and '
      'message contents are not attached.',
      style: TextStyle(fontSize: 11.5),
    ),
  );
}

class _CardBody extends StatelessWidget {
  const _CardBody({
    required this.title,
    required this.subtitle,
    required this.children,
    this.error,
    this.success,
  });
  final String title;
  final String subtitle;
  final List<Widget> children;
  final String? error;
  final String? success;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 21,
              height: 1.2,
              color: Color(0xff122238),
            ),
          ),
          const SizedBox(height: 7),
          Text(
            subtitle,
            style: const TextStyle(color: Color(0xff68778b), height: 1.4),
          ),
          const SizedBox(height: 16),
          if (error != null) ...[
            _MessageBanner(text: error!, error: true),
            const SizedBox(height: 10),
          ],
          if (success != null) ...[
            _MessageBanner(text: success!, error: false),
            const SizedBox(height: 10),
          ],
          ...children,
        ],
      ),
    ),
  );
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    this.working = false,
    this.icon,
    required this.onPressed,
  });
  final String label;
  final bool working;
  final IconData? icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 49,
    child: FilledButton.icon(
      onPressed: working ? null : onPressed,
      icon:
          working
              ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
              : Icon(icon ?? Icons.arrow_forward_rounded, size: 18),
      label: Text(
        working ? 'Please wait…' : label,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
  );
}

class _MessageBanner extends StatelessWidget {
  const _MessageBanner({required this.text, required this.error});
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: error ? const Color(0xffffeeee) : const Color(0xffe9f8f0),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: error ? const Color(0xffa13f3f) : const Color(0xff26744e),
        height: 1.4,
        fontSize: 13,
      ),
    ),
  );
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xffeef4ff),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: Color(0xff315783),
        height: 1.45,
        fontSize: 12.5,
      ),
    ),
  );
}

/// Applies the parent's in-app preference on top of the device's system scale.
/// Keeping the system scaler as the delegate preserves its nonlinear behavior.
class _PreferenceTextScaler extends TextScaler {
  const _PreferenceTextScaler(this.systemScaler, this.preferenceScale);

  final TextScaler systemScaler;
  final double preferenceScale;

  @override
  double scale(double fontSize) =>
      systemScaler.scale(fontSize * preferenceScale);

  // TextScaler still requires this deprecated compatibility getter.
  @override
  double get textScaleFactor {
    // ignore: deprecated_member_use
    return systemScaler.textScaleFactor * preferenceScale;
  }

  @override
  bool operator ==(Object other) =>
      other is _PreferenceTextScaler &&
      other.systemScaler == systemScaler &&
      other.preferenceScale == preferenceScale;

  @override
  int get hashCode => Object.hash(systemScaler, preferenceScale);
}
