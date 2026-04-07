# AVC Hybrid Mobile Implementation Plan

A phased implementation plan for building a mobile app with the existing Drupal/AVC backend.

## Overview

| Phase | Name | Duration | Outcome |
|-------|------|----------|---------|
| 1 | API Foundation | 1-2 weeks | Working API with authentication |
| 2 | Push Notifications | 1 week | Firebase integration |
| 3 | Mobile App Setup | 1 week | Dev environment + skeleton app |
| 4 | Authentication Flow | 1-2 weeks | Login, logout, token management |
| 5 | Core Screens | 3-4 weeks | Dashboard, Tasks, Groups, Profile |
| 6 | Advanced Features | 2-3 weeks | Notifications, Activity, Assets |
| 7 | Offline Support | 1-2 weeks | Caching, background sync |
| 8 | Testing & Polish | 2 weeks | QA, performance, bug fixes |
| 9 | App Store Release | 1-2 weeks | iOS App Store + Google Play |

**Total Estimated Duration: 14-19 weeks (3.5-5 months)**

---

## Phase 1: API Foundation

**Duration:** 1-2 weeks
**Goal:** Enable and configure API layer on existing AVC/Drupal backend

### 1.1 Enable JSON:API Module

```bash
# 1.1.1 Enable core JSON:API
ddev drush en jsonapi -y

# 1.1.2 Enable JSON:API Extras for customization
ddev composer require drupal/jsonapi_extras
ddev drush en jsonapi_extras -y

# 1.1.3 Verify API is working
curl -s https://avc.ddev.site/jsonapi | jq '.links'
```

**Deliverable:** JSON:API endpoints accessible at `/jsonapi/*`

### 1.2 Configure JSON:API Extras

```bash
# 1.2.1 Access configuration
# Navigate to: /admin/config/services/jsonapi/extras
```

**Configuration tasks:**
- [ ] 1.2.2 Enable/disable specific resource types
- [ ] 1.2.3 Configure field aliases for cleaner API
- [ ] 1.2.4 Set up path prefixes if needed
- [ ] 1.2.5 Configure pagination defaults

### 1.3 Install OAuth Authentication

```bash
# 1.3.1 Install Simple OAuth module
ddev composer require drupal/simple_oauth

# 1.3.2 Enable the module
ddev drush en simple_oauth -y

# 1.3.3 Generate OAuth keys
mkdir -p /var/www/html/keys
ddev drush simple-oauth:generate-keys /var/www/html/keys
```

### 1.4 Configure OAuth

**Navigate to:** `/admin/config/people/simple_oauth`

- [ ] 1.4.1 Set access token expiration: `3600` (1 hour)
- [ ] 1.4.2 Set refresh token expiration: `1209600` (14 days)
- [ ] 1.4.3 Set public key path: `/var/www/html/keys/public.key`
- [ ] 1.4.4 Set private key path: `/var/www/html/keys/private.key`

### 1.5 Create OAuth Consumer (Client)

**Navigate to:** `/admin/config/services/consumer`

```yaml
# 1.5.1 Create new consumer
Label: AVC Mobile App
Client ID: avc_mobile_app
New Secret: [generate secure secret]
Is Confidential: No (for mobile apps)
Redirect URI: avc://oauth/callback
User: (leave empty for public client)
Scopes: (select appropriate scopes)
```

- [ ] 1.5.2 Save and securely store client credentials

### 1.6 Configure CORS

```bash
# 1.6.1 Copy default services file
cp sites/default/default.services.yml sites/default/services.yml
```

```yaml
# 1.6.2 Edit sites/default/services.yml
parameters:
  cors.config:
    enabled: true
    allowedHeaders:
      - 'content-type'
      - 'authorization'
      - 'x-csrf-token'
    allowedMethods:
      - 'GET'
      - 'POST'
      - 'PATCH'
      - 'DELETE'
      - 'OPTIONS'
    allowedOrigins:
      - '*'  # Restrict in production
    allowedOriginsPatterns: []
    exposedHeaders: true
    maxAge: 1000
    supportsCredentials: true
```

```bash
# 1.6.3 Clear cache
ddev drush cr
```

### 1.7 Test API Authentication

```bash
# 1.7.1 Get access token
curl -X POST https://avc.ddev.site/oauth/token \
  -d "grant_type=password" \
  -d "client_id=avc_mobile_app" \
  -d "username=admin" \
  -d "password=admin" \
  -H "Content-Type: application/x-www-form-urlencoded"

# 1.7.2 Test authenticated request
curl https://avc.ddev.site/jsonapi/user/user \
  -H "Authorization: Bearer YOUR_ACCESS_TOKEN" \
  -H "Accept: application/vnd.api+json"
```

### 1.8 Document Available Endpoints

- [ ] 1.8.1 List all entity types exposed via JSON:API
- [ ] 1.8.2 Document authentication flow
- [ ] 1.8.3 Create Postman/Insomnia collection for testing

**Phase 1 Checklist:**
- [ ] JSON:API enabled and accessible
- [ ] OAuth authentication working
- [ ] CORS configured
- [ ] API documentation created
- [ ] Test collection created

---

## Phase 2: Push Notifications

**Duration:** 1 week
**Goal:** Enable Firebase Cloud Messaging for push notifications

### 2.1 Set Up Firebase Project

- [ ] 2.1.1 Go to [Firebase Console](https://console.firebase.google.com)
- [ ] 2.1.2 Create new project: "AVC Mobile"
- [ ] 2.1.3 Enable Cloud Messaging
- [ ] 2.1.4 Download `google-services.json` (Android)
- [ ] 2.1.5 Download `GoogleService-Info.plist` (iOS)

### 2.2 Get Firebase Server Credentials

- [ ] 2.2.1 Go to Project Settings > Service Accounts
- [ ] 2.2.2 Generate new private key (JSON file)
- [ ] 2.2.3 Store securely (do not commit to git)

### 2.3 Install Drupal Firebase Module

```bash
# 2.3.1 Install module
ddev composer require drupal/firebase

# 2.3.2 Enable module
ddev drush en firebase -y
```

### 2.4 Configure Firebase in Drupal

**Navigate to:** `/admin/config/services/firebase`

- [ ] 2.4.1 Upload or paste service account JSON
- [ ] 2.4.2 Configure sender ID
- [ ] 2.4.3 Test notification sending

### 2.5 Create Device Token Storage

```bash
# 2.5.1 Create custom module for device management
mkdir -p modules/custom/avc_mobile
```

```php
// 2.5.2 modules/custom/avc_mobile/avc_mobile.install
<?php

function avc_mobile_schema() {
  $schema['avc_device_tokens'] = [
    'description' => 'Stores mobile device push notification tokens',
    'fields' => [
      'id' => [
        'type' => 'serial',
        'unsigned' => TRUE,
        'not null' => TRUE,
      ],
      'uid' => [
        'type' => 'int',
        'unsigned' => TRUE,
        'not null' => TRUE,
      ],
      'token' => [
        'type' => 'varchar',
        'length' => 255,
        'not null' => TRUE,
      ],
      'platform' => [
        'type' => 'varchar',
        'length' => 10,
        'not null' => TRUE,
        'default' => 'android',
      ],
      'created' => [
        'type' => 'int',
        'not null' => TRUE,
      ],
      'updated' => [
        'type' => 'int',
        'not null' => TRUE,
      ],
    ],
    'primary key' => ['id'],
    'indexes' => [
      'uid' => ['uid'],
      'token' => ['token'],
    ],
  ];
  return $schema;
}
```

### 2.6 Create Token Registration Endpoint

```php
// 2.6.1 modules/custom/avc_mobile/src/Controller/DeviceController.php
<?php

namespace Drupal\avc_mobile\Controller;

use Drupal\Core\Controller\ControllerBase;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;

class DeviceController extends ControllerBase {

  public function registerToken(Request $request) {
    $data = json_decode($request->getContent(), TRUE);

    if (empty($data['token'])) {
      return new JsonResponse(['error' => 'Token required'], 400);
    }

    $uid = \Drupal::currentUser()->id();
    $token = $data['token'];
    $platform = $data['platform'] ?? 'android';

    \Drupal::database()->merge('avc_device_tokens')
      ->keys(['uid' => $uid, 'platform' => $platform])
      ->fields([
        'token' => $token,
        'updated' => \Drupal::time()->getRequestTime(),
      ])
      ->insertFields([
        'uid' => $uid,
        'token' => $token,
        'platform' => $platform,
        'created' => \Drupal::time()->getRequestTime(),
        'updated' => \Drupal::time()->getRequestTime(),
      ])
      ->execute();

    return new JsonResponse(['status' => 'registered']);
  }

  public function unregisterToken(Request $request) {
    $uid = \Drupal::currentUser()->id();

    \Drupal::database()->delete('avc_device_tokens')
      ->condition('uid', $uid)
      ->execute();

    return new JsonResponse(['status' => 'unregistered']);
  }
}
```

```yaml
# 2.6.2 modules/custom/avc_mobile/avc_mobile.routing.yml
avc_mobile.register_token:
  path: '/api/device/register'
  defaults:
    _controller: '\Drupal\avc_mobile\Controller\DeviceController::registerToken'
  methods: [POST]
  requirements:
    _user_is_logged_in: 'TRUE'

avc_mobile.unregister_token:
  path: '/api/device/unregister'
  defaults:
    _controller: '\Drupal\avc_mobile\Controller\DeviceController::unregisterToken'
  methods: [POST]
  requirements:
    _user_is_logged_in: 'TRUE'
```

### 2.7 Create Notification Service

```php
// 2.7.1 modules/custom/avc_mobile/src/Service/PushNotificationService.php
<?php

namespace Drupal\avc_mobile\Service;

use Drupal\firebase\Service\FirebaseMessageService;

class PushNotificationService {

  protected $firebase;

  public function __construct(FirebaseMessageService $firebase) {
    $this->firebase = $firebase;
  }

  public function sendToUser($uid, $title, $body, $data = []) {
    $tokens = $this->getUserTokens($uid);

    foreach ($tokens as $token) {
      $this->firebase->send([
        'token' => $token->token,
        'notification' => [
          'title' => $title,
          'body' => $body,
        ],
        'data' => $data,
      ]);
    }
  }

  protected function getUserTokens($uid) {
    return \Drupal::database()->select('avc_device_tokens', 't')
      ->fields('t', ['token', 'platform'])
      ->condition('uid', $uid)
      ->execute()
      ->fetchAll();
  }
}
```

### 2.8 Hook Into AVC Events

```php
// 2.8.1 modules/custom/avc_mobile/avc_mobile.module
<?php

use Drupal\node\NodeInterface;

/**
 * Implements hook_ENTITY_TYPE_insert() for workflow tasks.
 */
function avc_mobile_node_insert(NodeInterface $node) {
  if ($node->bundle() === 'task') {
    $assignee_id = $node->get('field_assigned_to')->target_id;
    if ($assignee_id) {
      $service = \Drupal::service('avc_mobile.push_notification');
      $service->sendToUser(
        $assignee_id,
        'New Task Assigned',
        $node->getTitle(),
        [
          'type' => 'task_assigned',
          'task_id' => $node->id(),
        ]
      );
    }
  }
}
```

### 2.9 Enable and Test Module

```bash
# 2.9.1 Enable custom module
ddev drush en avc_mobile -y

# 2.9.2 Run database updates
ddev drush updb -y

# 2.9.3 Clear cache
ddev drush cr
```

**Phase 2 Checklist:**
- [ ] Firebase project created
- [ ] Drupal Firebase module configured
- [ ] Device token storage created
- [ ] Token registration endpoints working
- [ ] Push notification service created
- [ ] Event hooks integrated
- [ ] Test notification sent successfully

---

## Phase 3: Mobile App Setup

**Duration:** 1 week
**Goal:** Set up mobile development environment and create app skeleton

### 3.1 Choose Framework

| Framework | Recommended For |
|-----------|-----------------|
| **Flutter** | Best performance, recommended |
| React Native | JavaScript team preference |
| Flet | Python-only team (simplified features) |

### 3.2 Flutter Setup (Recommended)

```bash
# 3.2.1 Install Flutter SDK
# Follow: https://docs.flutter.dev/get-started/install

# 3.2.2 Verify installation
flutter doctor

# 3.2.3 Create new project
flutter create avc_mobile
cd avc_mobile

# 3.2.4 Open in IDE
code .  # or: android-studio .
```

### 3.3 Add Dependencies

```yaml
# 3.3.1 Edit pubspec.yaml
dependencies:
  flutter:
    sdk: flutter

  # State Management
  flutter_riverpod: ^2.4.9
  riverpod_annotation: ^2.3.3

  # API & Networking
  dio: ^5.4.0
  retrofit: ^4.0.3
  json_annotation: ^4.8.1

  # Authentication
  flutter_secure_storage: ^9.0.0
  flutter_appauth: ^6.0.0

  # Firebase
  firebase_core: ^2.24.2
  firebase_messaging: ^14.7.10

  # UI Components
  flutter_svg: ^2.0.9
  cached_network_image: ^3.3.1
  shimmer: ^3.0.0

  # Utilities
  intl: ^0.18.1
  timeago: ^3.6.1
  connectivity_plus: ^5.0.2

  # Local Storage
  hive: ^2.2.3
  hive_flutter: ^1.1.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  build_runner: ^2.4.7
  retrofit_generator: ^8.0.6
  json_serializable: ^6.7.1
  riverpod_generator: ^2.3.9
  hive_generator: ^2.0.1
```

```bash
# 3.3.2 Install dependencies
flutter pub get
```

### 3.4 Configure Firebase for Mobile

```bash
# 3.4.1 Install FlutterFire CLI
dart pub global activate flutterfire_cli

# 3.4.2 Configure Firebase
flutterfire configure --project=avc-mobile
```

- [ ] 3.4.3 Copy `google-services.json` to `android/app/`
- [ ] 3.4.4 Copy `GoogleService-Info.plist` to `ios/Runner/`

### 3.5 Create Project Structure

```bash
# 3.5.1 Create directory structure
mkdir -p lib/{core,features,shared}
mkdir -p lib/core/{api,auth,config,services,utils}
mkdir -p lib/features/{auth,dashboard,tasks,groups,profile,notifications}
mkdir -p lib/shared/{models,widgets,theme}
```

```
lib/
├── main.dart
├── app.dart
├── core/
│   ├── api/
│   │   ├── api_client.dart
│   │   ├── api_endpoints.dart
│   │   └── interceptors/
│   ├── auth/
│   │   ├── auth_service.dart
│   │   └── token_storage.dart
│   ├── config/
│   │   └── app_config.dart
│   ├── services/
│   │   └── push_notification_service.dart
│   └── utils/
│       └── logger.dart
├── features/
│   ├── auth/
│   │   ├── screens/
│   │   ├── widgets/
│   │   └── providers/
│   ├── dashboard/
│   ├── tasks/
│   ├── groups/
│   ├── profile/
│   └── notifications/
└── shared/
    ├── models/
    ├── widgets/
    └── theme/
```

### 3.6 Create App Configuration

```dart
// 3.6.1 lib/core/config/app_config.dart
class AppConfig {
  static const String baseUrl = 'https://avc.example.com';
  static const String apiPath = '/jsonapi';
  static const String oauthPath = '/oauth/token';

  static const String clientId = 'avc_mobile_app';
  // Note: For public clients, no secret needed

  static const Duration accessTokenExpiry = Duration(hours: 1);
  static const Duration refreshTokenExpiry = Duration(days: 14);
}
```

### 3.7 Create Basic API Client

```dart
// 3.7.1 lib/core/api/api_client.dart
import 'package:dio/dio.dart';
import '../config/app_config.dart';
import '../auth/token_storage.dart';

class ApiClient {
  late final Dio _dio;
  final TokenStorage _tokenStorage;

  ApiClient(this._tokenStorage) {
    _dio = Dio(BaseOptions(
      baseUrl: AppConfig.baseUrl,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'Accept': 'application/vnd.api+json',
        'Content-Type': 'application/vnd.api+json',
      },
    ));

    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        final token = await _tokenStorage.getAccessToken();
        if (token != null) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        handler.next(options);
      },
      onError: (error, handler) async {
        if (error.response?.statusCode == 401) {
          // Try to refresh token
          final refreshed = await _refreshToken();
          if (refreshed) {
            // Retry request
            final response = await _dio.fetch(error.requestOptions);
            handler.resolve(response);
            return;
          }
        }
        handler.next(error);
      },
    ));
  }

  Future<bool> _refreshToken() async {
    // Token refresh logic
    return false;
  }

  Future<Response> get(String path, {Map<String, dynamic>? params}) {
    return _dio.get(path, queryParameters: params);
  }

  Future<Response> post(String path, {dynamic data}) {
    return _dio.post(path, data: data);
  }

  Future<Response> patch(String path, {dynamic data}) {
    return _dio.patch(path, data: data);
  }

  Future<Response> delete(String path) {
    return _dio.delete(path);
  }
}
```

### 3.8 Run Initial Build

```bash
# 3.8.1 Generate code (for annotations)
flutter pub run build_runner build --delete-conflicting-outputs

# 3.8.2 Run on device/emulator
flutter run
```

**Phase 3 Checklist:**
- [ ] Development environment set up
- [ ] Flutter project created
- [ ] Dependencies installed
- [ ] Firebase configured
- [ ] Project structure created
- [ ] Basic API client implemented
- [ ] App runs on device/emulator

---

## Phase 4: Authentication Flow

**Duration:** 1-2 weeks
**Goal:** Implement complete login, logout, and token management

### 4.1 Create Token Storage

```dart
// 4.1.1 lib/core/auth/token_storage.dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class TokenStorage {
  final _storage = const FlutterSecureStorage();

  static const _accessTokenKey = 'access_token';
  static const _refreshTokenKey = 'refresh_token';
  static const _expiresAtKey = 'expires_at';

  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
    required DateTime expiresAt,
  }) async {
    await _storage.write(key: _accessTokenKey, value: accessToken);
    await _storage.write(key: _refreshTokenKey, value: refreshToken);
    await _storage.write(
      key: _expiresAtKey,
      value: expiresAt.toIso8601String(),
    );
  }

  Future<String?> getAccessToken() async {
    final expiresAtStr = await _storage.read(key: _expiresAtKey);
    if (expiresAtStr != null) {
      final expiresAt = DateTime.parse(expiresAtStr);
      if (DateTime.now().isAfter(expiresAt)) {
        return null; // Token expired
      }
    }
    return await _storage.read(key: _accessTokenKey);
  }

  Future<String?> getRefreshToken() async {
    return await _storage.read(key: _refreshTokenKey);
  }

  Future<void> clearTokens() async {
    await _storage.deleteAll();
  }

  Future<bool> hasValidToken() async {
    final token = await getAccessToken();
    return token != null;
  }
}
```

### 4.2 Create Auth Service

```dart
// 4.2.1 lib/core/auth/auth_service.dart
import 'package:dio/dio.dart';
import '../config/app_config.dart';
import 'token_storage.dart';

class AuthService {
  final Dio _dio;
  final TokenStorage _tokenStorage;

  AuthService(this._tokenStorage)
      : _dio = Dio(BaseOptions(baseUrl: AppConfig.baseUrl));

  Future<bool> login(String username, String password) async {
    try {
      final response = await _dio.post(
        AppConfig.oauthPath,
        data: {
          'grant_type': 'password',
          'client_id': AppConfig.clientId,
          'username': username,
          'password': password,
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
        ),
      );

      if (response.statusCode == 200) {
        final data = response.data;
        final expiresIn = data['expires_in'] as int;
        final expiresAt = DateTime.now().add(Duration(seconds: expiresIn));

        await _tokenStorage.saveTokens(
          accessToken: data['access_token'],
          refreshToken: data['refresh_token'],
          expiresAt: expiresAt,
        );
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  Future<bool> refreshToken() async {
    try {
      final refreshToken = await _tokenStorage.getRefreshToken();
      if (refreshToken == null) return false;

      final response = await _dio.post(
        AppConfig.oauthPath,
        data: {
          'grant_type': 'refresh_token',
          'client_id': AppConfig.clientId,
          'refresh_token': refreshToken,
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
        ),
      );

      if (response.statusCode == 200) {
        final data = response.data;
        final expiresIn = data['expires_in'] as int;
        final expiresAt = DateTime.now().add(Duration(seconds: expiresIn));

        await _tokenStorage.saveTokens(
          accessToken: data['access_token'],
          refreshToken: data['refresh_token'],
          expiresAt: expiresAt,
        );
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  Future<void> logout() async {
    await _tokenStorage.clearTokens();
  }

  Future<bool> isAuthenticated() async {
    return await _tokenStorage.hasValidToken();
  }
}
```

### 4.3 Create Auth Provider (Riverpod)

```dart
// 4.3.1 lib/features/auth/providers/auth_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/auth/auth_service.dart';
import '../../../core/auth/token_storage.dart';

final tokenStorageProvider = Provider((ref) => TokenStorage());

final authServiceProvider = Provider((ref) {
  return AuthService(ref.read(tokenStorageProvider));
});

enum AuthStatus { initial, authenticated, unauthenticated, loading }

class AuthState {
  final AuthStatus status;
  final String? error;

  AuthState({required this.status, this.error});

  AuthState copyWith({AuthStatus? status, String? error}) {
    return AuthState(
      status: status ?? this.status,
      error: error,
    );
  }
}

class AuthNotifier extends StateNotifier<AuthState> {
  final AuthService _authService;

  AuthNotifier(this._authService)
      : super(AuthState(status: AuthStatus.initial)) {
    _checkAuthStatus();
  }

  Future<void> _checkAuthStatus() async {
    final isAuthenticated = await _authService.isAuthenticated();
    state = AuthState(
      status: isAuthenticated
          ? AuthStatus.authenticated
          : AuthStatus.unauthenticated,
    );
  }

  Future<void> login(String username, String password) async {
    state = state.copyWith(status: AuthStatus.loading);

    final success = await _authService.login(username, password);

    if (success) {
      state = AuthState(status: AuthStatus.authenticated);
    } else {
      state = AuthState(
        status: AuthStatus.unauthenticated,
        error: 'Invalid credentials',
      );
    }
  }

  Future<void> logout() async {
    await _authService.logout();
    state = AuthState(status: AuthStatus.unauthenticated);
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(ref.read(authServiceProvider));
});
```

### 4.4 Create Login Screen

```dart
// 4.4.1 lib/features/auth/screens/login_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    if (_formKey.currentState!.validate()) {
      await ref.read(authProvider.notifier).login(
            _usernameController.text,
            _passwordController.text,
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);

    ref.listen<AuthState>(authProvider, (previous, next) {
      if (next.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(next.error!)),
        );
      }
    });

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Logo
                const Icon(
                  Icons.group_work,
                  size: 80,
                  color: Colors.blue,
                ),
                const SizedBox(height: 16),
                const Text(
                  'AVC Mobile',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 48),

                // Username field
                TextFormField(
                  controller: _usernameController,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    prefixIcon: Icon(Icons.person),
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter your username';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                // Password field
                TextFormField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.lock),
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility
                            : Icons.visibility_off,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscurePassword = !_obscurePassword;
                        });
                      },
                    ),
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter your password';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 24),

                // Login button
                ElevatedButton(
                  onPressed: authState.status == AuthStatus.loading
                      ? null
                      : _handleLogin,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: authState.status == AuthStatus.loading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Login'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
```

### 4.5 Create Auth Router

```dart
// 4.5.1 lib/app.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'features/auth/providers/auth_provider.dart';
import 'features/auth/screens/login_screen.dart';
import 'features/dashboard/screens/dashboard_screen.dart';

class AvcApp extends ConsumerWidget {
  const AvcApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authProvider);

    return MaterialApp(
      title: 'AVC Mobile',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: _buildHome(authState),
    );
  }

  Widget _buildHome(AuthState authState) {
    switch (authState.status) {
      case AuthStatus.initial:
      case AuthStatus.loading:
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
      case AuthStatus.authenticated:
        return const DashboardScreen();
      case AuthStatus.unauthenticated:
        return const LoginScreen();
    }
  }
}
```

### 4.6 Register FCM Token After Login

```dart
// 4.6.1 Add to auth_provider.dart after successful login
Future<void> _registerPushToken() async {
  final fcmToken = await FirebaseMessaging.instance.getToken();
  if (fcmToken != null) {
    await _apiClient.post('/api/device/register', data: {
      'token': fcmToken,
      'platform': Platform.isIOS ? 'ios' : 'android',
    });
  }
}
```

**Phase 4 Checklist:**
- [ ] Token storage implemented
- [ ] Auth service with login/logout/refresh
- [ ] Auth state management (Riverpod)
- [ ] Login screen UI
- [ ] Auth-based routing
- [ ] FCM token registration after login
- [ ] Token refresh working
- [ ] Logout clears tokens

---

## Phase 5: Core Screens

**Duration:** 3-4 weeks
**Goal:** Build main app screens: Dashboard, Tasks, Groups, Profile

### 5.1 Dashboard Screen

**5.1.1** Create user model
**5.1.2** Create dashboard API service
**5.1.3** Create dashboard provider
**5.1.4** Build dashboard UI with:
- [ ] User greeting
- [ ] Task summary (pending, in progress, completed counts)
- [ ] Recent activity feed
- [ ] Quick actions

### 5.2 Tasks Screen

**5.2.1** Create task model
**5.2.2** Create tasks API service
**5.2.3** Create tasks provider with filtering
**5.2.4** Build tasks list UI with:
- [ ] Task list with status indicators
- [ ] Filter by status (All, Pending, In Progress, Completed)
- [ ] Pull to refresh
- [ ] Task detail view
- [ ] Status update action

### 5.3 Groups Screen

**5.3.1** Create group model
**5.3.2** Create groups API service
**5.3.3** Create groups provider
**5.3.4** Build groups UI with:
- [ ] Groups list
- [ ] Group detail view
- [ ] Group members list
- [ ] Group tasks/activity

### 5.4 Profile Screen

**5.4.1** Create profile model
**5.4.2** Create profile API service
**5.4.3** Create profile provider
**5.4.4** Build profile UI with:
- [ ] User avatar and info
- [ ] Statistics (tasks, groups, etc.)
- [ ] Settings link
- [ ] Logout button

### 5.5 Navigation

**5.5.1** Implement bottom navigation bar
**5.5.2** Create navigation provider
**5.5.3** Add navigation between screens

**Phase 5 Checklist:**
- [ ] Dashboard screen complete
- [ ] Tasks screen complete
- [ ] Groups screen complete
- [ ] Profile screen complete
- [ ] Bottom navigation working
- [ ] All screens fetch real data from API

---

## Phase 6: Advanced Features

**Duration:** 2-3 weeks
**Goal:** Add notifications, activity feed, asset management

### 6.1 Notifications Screen

- [ ] 6.1.1 Create notification model
- [ ] 6.1.2 Create notifications API service
- [ ] 6.1.3 Build notifications list UI
- [ ] 6.1.4 Handle notification tap (deep linking)
- [ ] 6.1.5 Mark as read functionality

### 6.2 Activity Feed

- [ ] 6.2.1 Create activity model
- [ ] 6.2.2 Fetch activity stream from API
- [ ] 6.2.3 Build activity feed UI
- [ ] 6.2.4 Infinite scroll pagination

### 6.3 Assets/Documents

- [ ] 6.3.1 Create asset model
- [ ] 6.3.2 Create assets API service
- [ ] 6.3.3 Build assets list UI
- [ ] 6.3.4 Asset detail/preview
- [ ] 6.3.5 File download functionality

### 6.4 Push Notification Handling

- [ ] 6.4.1 Handle foreground notifications
- [ ] 6.4.2 Handle background notifications
- [ ] 6.4.3 Handle notification tap routing
- [ ] 6.4.4 Badge count management

```dart
// 6.4.5 lib/core/services/push_notification_service.dart
class PushNotificationService {
  Future<void> initialize() async {
    // Request permission
    await FirebaseMessaging.instance.requestPermission();

    // Handle foreground messages
    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

    // Handle background message tap
    FirebaseMessaging.onMessageOpenedApp.listen(_handleMessageTap);

    // Handle terminated state tap
    final initialMessage =
        await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null) {
      _handleMessageTap(initialMessage);
    }
  }

  void _handleForegroundMessage(RemoteMessage message) {
    // Show local notification
  }

  void _handleMessageTap(RemoteMessage message) {
    // Navigate to relevant screen based on message.data
  }
}
```

**Phase 6 Checklist:**
- [ ] Notifications screen complete
- [ ] Activity feed complete
- [ ] Assets/documents screen complete
- [ ] Push notifications fully integrated
- [ ] Deep linking from notifications working

---

## Phase 7: Offline Support

**Duration:** 1-2 weeks
**Goal:** Enable offline access and background sync

### 7.1 Local Database Setup

```dart
// 7.1.1 Set up Hive for local storage
await Hive.initFlutter();
Hive.registerAdapter(TaskAdapter());
Hive.registerAdapter(GroupAdapter());
await Hive.openBox<Task>('tasks');
await Hive.openBox<Group>('groups');
```

### 7.2 Implement Cache-First Strategy

- [ ] 7.2.1 Cache API responses locally
- [ ] 7.2.2 Return cached data when offline
- [ ] 7.2.3 Update cache when online

### 7.3 Pending Actions Queue

- [ ] 7.3.1 Queue actions when offline
- [ ] 7.3.2 Sync queue when online
- [ ] 7.3.3 Handle conflicts

### 7.4 Connectivity Handling

- [ ] 7.4.1 Monitor connectivity status
- [ ] 7.4.2 Show offline indicator
- [ ] 7.4.3 Trigger sync on reconnect

**Phase 7 Checklist:**
- [ ] Local database set up
- [ ] Caching implemented
- [ ] Offline mode working
- [ ] Background sync working
- [ ] Conflict resolution handled

---

## Phase 8: Testing & Polish

**Duration:** 2 weeks
**Goal:** QA, performance optimization, bug fixes

### 8.1 Testing

- [ ] 8.1.1 Unit tests for services
- [ ] 8.1.2 Widget tests for screens
- [ ] 8.1.3 Integration tests for flows
- [ ] 8.1.4 Manual QA on multiple devices

### 8.2 Performance

- [ ] 8.2.1 Profile app performance
- [ ] 8.2.2 Optimize image loading
- [ ] 8.2.3 Reduce unnecessary rebuilds
- [ ] 8.2.4 Minimize API calls

### 8.3 Polish

- [ ] 8.3.1 Loading states
- [ ] 8.3.2 Error handling UI
- [ ] 8.3.3 Empty states
- [ ] 8.3.4 Animations/transitions
- [ ] 8.3.5 App icon and splash screen

### 8.4 Accessibility

- [ ] 8.4.1 Screen reader support
- [ ] 8.4.2 Sufficient color contrast
- [ ] 8.4.3 Touch target sizes

**Phase 8 Checklist:**
- [ ] All tests passing
- [ ] Performance acceptable
- [ ] UI polished
- [ ] Accessibility verified
- [ ] No critical bugs

---

## Phase 9: App Store Release

**Duration:** 1-2 weeks
**Goal:** Submit to iOS App Store and Google Play

### 9.1 Prepare Assets

- [ ] 9.1.1 App icon (multiple sizes)
- [ ] 9.1.2 Feature graphic (Google Play)
- [ ] 9.1.3 Screenshots (multiple devices)
- [ ] 9.1.4 App description
- [ ] 9.1.5 Privacy policy URL
- [ ] 9.1.6 Terms of service URL

### 9.2 Android Release

```bash
# 9.2.1 Create keystore
keytool -genkey -v -keystore avc-release-key.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias avc

# 9.2.2 Configure signing in android/app/build.gradle

# 9.2.3 Build release APK/AAB
flutter build appbundle --release
```

- [ ] 9.2.4 Create Google Play Console account ($25 one-time)
- [ ] 9.2.5 Create app listing
- [ ] 9.2.6 Upload AAB
- [ ] 9.2.7 Complete content rating
- [ ] 9.2.8 Submit for review

### 9.3 iOS Release

```bash
# 9.3.1 Build iOS release
flutter build ios --release
```

- [ ] 9.3.2 Apple Developer account ($99/year)
- [ ] 9.3.3 Create App Store Connect listing
- [ ] 9.3.4 Configure certificates and provisioning
- [ ] 9.3.5 Archive and upload via Xcode
- [ ] 9.3.6 Submit for review

### 9.4 Post-Launch

- [ ] 9.4.1 Monitor crash reports
- [ ] 9.4.2 Monitor user feedback
- [ ] 9.4.3 Plan first update

**Phase 9 Checklist:**
- [ ] Android app published
- [ ] iOS app published
- [ ] Monitoring set up
- [ ] Update plan ready

---

## Summary Timeline

```
Week 1-2:   Phase 1 - API Foundation
Week 3:     Phase 2 - Push Notifications
Week 4:     Phase 3 - Mobile App Setup
Week 5-6:   Phase 4 - Authentication Flow
Week 7-10:  Phase 5 - Core Screens
Week 11-13: Phase 6 - Advanced Features
Week 14-15: Phase 7 - Offline Support
Week 16-17: Phase 8 - Testing & Polish
Week 18-19: Phase 9 - App Store Release
```

**Total: ~19 weeks (4.5 months)**

---

## Resource Requirements

| Role | Effort | Notes |
|------|--------|-------|
| Drupal Developer | 2-3 weeks | Phase 1-2 (API + Push) |
| Flutter Developer | 12-14 weeks | Phase 3-8 |
| UI/UX Designer | 2-3 weeks | Screens, assets |
| QA Tester | 2 weeks | Phase 8 |

---

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| API changes break app | Version API, maintain compatibility |
| Push notifications fail | Implement fallback (in-app polling) |
| App store rejection | Follow guidelines, test thoroughly |
| Offline sync conflicts | Implement conflict resolution strategy |
| Performance issues | Profile early, optimize images |

---

## Next Steps

1. **Get approval** for this implementation plan
2. **Assign resources** (Drupal dev, Flutter dev)
3. **Start Phase 1** - Enable API on existing AVC site
4. **Set up project tracking** (GitHub issues, Jira, etc.)
