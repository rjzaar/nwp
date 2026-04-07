# AVC Hybrid Mobile Approach

Keep the existing Drupal/AVC backend and add a mobile frontend - the fastest path to AVC mobile.

## Why Hybrid is the Best Approach for AVC

| Factor | Full Rebuild | Hybrid Approach |
|--------|--------------|-----------------|
| **Backend development** | 6-12 months | 0 (already done) |
| **Feature parity** | Must rebuild everything | Already working |
| **Risk** | High (new untested code) | Low (proven backend) |
| **Time to mobile** | 9-12+ months | 2-4 months |
| **Team skills needed** | Full-stack | Mobile frontend only |

## What AVC Already Has (Discovery)

Based on analysis of the AVC codebase, these API capabilities are **already installed**:

### GraphQL API (Installed)

```yaml
# From avc/composer.json
drupal/graphql: ^4.9.0          # GraphQL API server
drupal/graphql_oauth: ^1.0.0    # OAuth for GraphQL
```

**This means:** AVC can expose a GraphQL API with OAuth authentication out of the box.

### JSON:API (Drupal Core)

JSON:API is included in Drupal 10 core. Just enable the module:

```bash
ddev drush en jsonapi
```

**Endpoints automatically available:**
- `/jsonapi/node/{type}` - All content types
- `/jsonapi/user/user` - Users
- `/jsonapi/group/group` - Groups
- `/jsonapi/taxonomy_term/{vocabulary}` - Taxonomies

### Search API + Solr (Installed)

```yaml
drupal/search_api: ^1.35
drupal/search_api_solr: ^4.3.10
```

**This enables:** Faceted search, filtering, full-text search via API.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     MOBILE APPS                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │   Flutter    │  │ React Native │  │    Flet      │          │
│  │     App      │  │     App      │  │  (Python)    │          │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘          │
│         │                 │                  │                   │
│         └────────────┬────┴──────────────────┘                   │
│                      │                                           │
│              ┌───────▼───────┐                                  │
│              │  API Client   │                                  │
│              │  - GraphQL    │                                  │
│              │  - JSON:API   │                                  │
│              │  - OAuth JWT  │                                  │
│              └───────┬───────┘                                  │
└──────────────────────┼──────────────────────────────────────────┘
                       │ HTTPS
                       │
┌──────────────────────┼──────────────────────────────────────────┐
│                      │     EXISTING DRUPAL/AVC BACKEND          │
│              ┌───────▼───────┐                                  │
│              │   API Layer   │                                  │
│              │ ┌───────────┐ │                                  │
│              │ │  GraphQL  │ │  ← Already installed             │
│              │ │ + OAuth   │ │  ← Already installed             │
│              │ └───────────┘ │                                  │
│              │ ┌───────────┐ │                                  │
│              │ │ JSON:API  │ │  ← Drupal core (enable)          │
│              │ └───────────┘ │                                  │
│              │ ┌───────────┐ │                                  │
│              │ │Simple OAuth│ │  ← Add for JWT                  │
│              │ └───────────┘ │                                  │
│              └───────┬───────┘                                  │
│                      │                                           │
│  ┌───────────────────▼───────────────────────────────────────┐  │
│  │                    AVC MODULES                             │  │
│  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐         │  │
│  │  │ avc_member  │ │  avc_group  │ │  avc_guild  │         │  │
│  │  │ - Profiles  │ │ - Groups    │ │ - Mentorship│         │  │
│  │  │ - Worklists │ │ - Dashboards│ │ - Scoring   │         │  │
│  │  └─────────────┘ └─────────────┘ └─────────────┘         │  │
│  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐         │  │
│  │  │  avc_asset  │ │avc_notific. │ │ workflow_   │         │  │
│  │  │ - Documents │ │ - Alerts    │ │ assignment  │         │  │
│  │  │ - Projects  │ │ - Digests   │ │ - Tasks     │         │  │
│  │  └─────────────┘ └─────────────┘ └─────────────┘         │  │
│  └───────────────────────────────────────────────────────────┘  │
│                      │                                           │
│              ┌───────▼───────┐                                  │
│              │   Database    │                                  │
│              │   (MariaDB)   │                                  │
│              └───────────────┘                                  │
│                                                                  │
│  ┌─────────────────┐  ┌─────────────────┐                      │
│  │  File Storage   │  │  Search (Solr)  │                      │
│  └─────────────────┘  └─────────────────┘                      │
└──────────────────────────────────────────────────────────────────┘

                       │
                       │ FCM (Firebase Cloud Messaging)
                       ▼
┌──────────────────────────────────────────────────────────────────┐
│                    PUSH NOTIFICATIONS                            │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                    Firebase                                  │ │
│  │  - Cloud Messaging (FCM)                                    │ │
│  │  - Drupal module: drupal/firebase                           │ │
│  └─────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

---

## Implementation Plan

### Phase 1: Enable API Layer (1-2 weeks)

#### Step 1.1: Enable JSON:API

```bash
# Enable JSON:API (Drupal core)
ddev drush en jsonapi jsonapi_extras -y

# Verify endpoints
curl https://avc.ddev.site/jsonapi
```

**JSON:API Extras** allows customizing:
- Which entities are exposed
- Field aliasing
- Endpoint paths

#### Step 1.2: Configure GraphQL (Already Installed)

```bash
# Enable GraphQL modules
ddev drush en graphql graphql_core -y

# Access GraphQL explorer
# https://avc.ddev.site/graphql/explorer
```

Create a custom schema for AVC entities in:
`modules/custom/avc_graphql/src/Plugin/GraphQL/Schema/AvcSchema.php`

#### Step 1.3: Add Authentication

```bash
# Install Simple OAuth for JWT tokens
ddev composer require drupal/simple_oauth
ddev drush en simple_oauth -y

# Generate keys
ddev drush simple-oauth:generate-keys ../keys
```

Configure at `/admin/config/people/simple_oauth`:
- Access token expiration: 3600 (1 hour)
- Refresh token expiration: 1209600 (14 days)

#### Step 1.4: Configure CORS

Create/edit `sites/default/services.yml`:

```yaml
parameters:
  cors.config:
    enabled: true
    allowedHeaders: ['*']
    allowedMethods: ['GET', 'POST', 'PATCH', 'DELETE', 'OPTIONS']
    allowedOrigins: ['*']  # Restrict in production
    allowedOriginsPatterns: []
    exposedHeaders: false
    maxAge: 1000
    supportsCredentials: true
```

### Phase 2: Add Push Notifications (1 week)

#### Step 2.1: Install Firebase Module

```bash
ddev composer require drupal/firebase
ddev drush en firebase -y
```

#### Step 2.2: Configure Firebase

1. Create Firebase project at https://console.firebase.google.com
2. Get server key from Project Settings > Cloud Messaging
3. Configure at `/admin/config/services/firebase`

#### Step 2.3: Register Device Tokens

Create endpoint for mobile apps to register tokens:

```php
// modules/custom/avc_mobile/src/Controller/DeviceController.php
public function registerToken(Request $request) {
  $data = json_decode($request->getContent(), TRUE);
  $token = $data['token'];
  $uid = \Drupal::currentUser()->id();

  // Store token in database
  \Drupal::database()->merge('avc_device_tokens')
    ->key(['uid' => $uid])
    ->fields(['token' => $token, 'updated' => time()])
    ->execute();

  return new JsonResponse(['status' => 'registered']);
}
```

### Phase 3: Build Mobile App (4-8 weeks)

#### Option A: Flutter (Recommended)

```dart
// pubspec.yaml
dependencies:
  flutter:
    sdk: flutter
  graphql_flutter: ^5.1.0
  json_api: ^5.0.0
  firebase_messaging: ^14.0.0
  flutter_secure_storage: ^8.0.0
```

```dart
// lib/services/avc_api.dart
import 'package:graphql_flutter/graphql_flutter.dart';

class AvcApi {
  final String baseUrl = 'https://avc.example.com';

  late GraphQLClient _client;

  Future<void> init(String token) async {
    final httpLink = HttpLink('$baseUrl/graphql');
    final authLink = AuthLink(getToken: () => 'Bearer $token');

    _client = GraphQLClient(
      link: authLink.concat(httpLink),
      cache: GraphQLCache(),
    );
  }

  Future<List<Task>> getMyTasks() async {
    const query = '''
      query GetMyTasks {
        myTasks {
          id
          title
          status
          assignedTo {
            name
          }
          group {
            name
          }
        }
      }
    ''';

    final result = await _client.query(QueryOptions(document: gql(query)));
    return (result.data?['myTasks'] as List)
        .map((t) => Task.fromJson(t))
        .toList();
  }
}
```

#### Option B: React Native with Expo

```javascript
// package.json
{
  "dependencies": {
    "@apollo/client": "^3.8.0",
    "graphql": "^16.8.0",
    "@react-native-firebase/messaging": "^18.0.0",
    "expo-secure-store": "~12.0.0"
  }
}
```

```javascript
// src/services/avcApi.js
import { ApolloClient, InMemoryCache, createHttpLink } from '@apollo/client';
import { setContext } from '@apollo/client/link/context';

const httpLink = createHttpLink({
  uri: 'https://avc.example.com/graphql',
});

const authLink = setContext(async (_, { headers }) => {
  const token = await SecureStore.getItemAsync('auth_token');
  return {
    headers: {
      ...headers,
      authorization: token ? `Bearer ${token}` : '',
    },
  };
});

export const client = new ApolloClient({
  link: authLink.concat(httpLink),
  cache: new InMemoryCache(),
});
```

#### Option C: Flet (Python - Simplified)

```python
# requirements.txt
flet>=0.25
gql[requests]
firebase-admin
```

```python
# main.py
import flet as ft
from gql import gql, Client
from gql.transport.requests import RequestsHTTPTransport

class AvcApi:
    def __init__(self, base_url: str, token: str):
        transport = RequestsHTTPTransport(
            url=f"{base_url}/graphql",
            headers={"Authorization": f"Bearer {token}"}
        )
        self.client = Client(transport=transport)

    def get_my_tasks(self):
        query = gql("""
            query GetMyTasks {
                myTasks {
                    id
                    title
                    status
                }
            }
        """)
        return self.client.execute(query)

def main(page: ft.Page):
    page.title = "AVC Mobile"

    api = AvcApi("https://avc.example.com", "your_token")
    tasks = api.get_my_tasks()

    task_list = ft.ListView(expand=True)
    for task in tasks['myTasks']:
        task_list.controls.append(
            ft.ListTile(
                title=ft.Text(task['title']),
                subtitle=ft.Text(task['status'])
            )
        )

    page.add(task_list)

ft.app(target=main)
```

---

## API Endpoints Reference

### Authentication

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/oauth/token` | POST | Get access token |
| `/oauth/token` | POST | Refresh token (grant_type=refresh_token) |
| `/user/logout` | POST | Invalidate token |

**Token Request:**
```bash
curl -X POST https://avc.example.com/oauth/token \
  -d "grant_type=password" \
  -d "client_id=mobile_app" \
  -d "client_secret=secret" \
  -d "username=user@example.com" \
  -d "password=password"
```

**Response:**
```json
{
  "access_token": "eyJhbGciOiJSUzI1NiJ9...",
  "token_type": "Bearer",
  "expires_in": 3600,
  "refresh_token": "def50200..."
}
```

### JSON:API Endpoints

| Resource | Endpoint | Notes |
|----------|----------|-------|
| Users | `/jsonapi/user/user` | Member profiles |
| Groups | `/jsonapi/group/group` | AVC groups |
| Tasks | `/jsonapi/node/task` | Workflow tasks |
| Assets | `/jsonapi/node/asset` | Documents/projects |
| Comments | `/jsonapi/comment/comment` | Activity comments |

**Example: Get user's tasks**
```bash
curl https://avc.example.com/jsonapi/node/task \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.api+json" \
  -G --data-urlencode "filter[field_assigned_to.id]=$USER_ID"
```

### GraphQL Queries

```graphql
# Get current user profile
query Me {
  me {
    id
    name
    email
    avatar
    groups {
      id
      name
      role
    }
    worklist {
      pending
      inProgress
      completed
    }
  }
}

# Get group dashboard
query GroupDashboard($groupId: ID!) {
  group(id: $groupId) {
    id
    name
    members {
      id
      name
      role
    }
    tasks {
      id
      title
      status
      assignedTo {
        name
      }
    }
    recentActivity {
      type
      description
      timestamp
    }
  }
}

# Get workflow tasks
query MyTasks($status: TaskStatus) {
  myTasks(status: $status) {
    id
    title
    description
    status
    priority
    dueDate
    group {
      name
    }
    assignedBy {
      name
    }
  }
}

# Update task status
mutation UpdateTaskStatus($id: ID!, $status: TaskStatus!) {
  updateTask(id: $id, input: { status: $status }) {
    id
    status
    updatedAt
  }
}
```

---

## Mobile App Screens Mapping

| AVC Web Feature | Mobile Screen | API Source |
|-----------------|---------------|------------|
| Member Dashboard | Home/Dashboard | `query Me` |
| Worklist | Tasks Tab | `query MyTasks` |
| Group Dashboard | Group Detail | `query GroupDashboard` |
| Guild Page | Guild Detail | `query Guild` |
| Asset List | Assets Tab | `/jsonapi/node/asset` |
| Notifications | Notifications Tab | `/jsonapi/notification` + FCM |
| Profile | Profile Screen | `query Me` |
| Activity Feed | Activity Tab | `query ActivityFeed` |

---

## Push Notifications Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                        DRUPAL/AVC                               │
│                                                                  │
│  Event Occurs (new task assigned, comment, etc.)                │
│           │                                                      │
│           ▼                                                      │
│  ┌─────────────────┐                                            │
│  │ Hook/Event      │                                            │
│  │ Subscriber      │                                            │
│  └────────┬────────┘                                            │
│           │                                                      │
│           ▼                                                      │
│  ┌─────────────────┐    ┌─────────────────┐                    │
│  │ Firebase Module │───▶│ Firebase API    │                    │
│  └─────────────────┘    └────────┬────────┘                    │
└──────────────────────────────────┼──────────────────────────────┘
                                   │
                                   ▼
                    ┌─────────────────────────┐
                    │   Firebase Cloud        │
                    │   Messaging (FCM)       │
                    └────────────┬────────────┘
                                 │
              ┌──────────────────┼──────────────────┐
              │                  │                  │
              ▼                  ▼                  ▼
      ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
      │   Android   │    │    iOS      │    │    Web      │
      │   Device    │    │   Device    │    │   Browser   │
      └─────────────┘    └─────────────┘    └─────────────┘
```

### Notification Types

```php
// modules/custom/avc_mobile/src/NotificationService.php

class NotificationService {

  public function sendTaskAssigned(NodeInterface $task, UserInterface $assignee) {
    $this->send($assignee, [
      'title' => 'New Task Assigned',
      'body' => $task->getTitle(),
      'data' => [
        'type' => 'task_assigned',
        'task_id' => $task->id(),
        'group_id' => $task->get('field_group')->target_id,
      ],
    ]);
  }

  public function sendWorkflowUpdate(NodeInterface $task, string $newStatus) {
    $this->send($task->getOwner(), [
      'title' => 'Task Status Updated',
      'body' => "{$task->getTitle()} is now {$newStatus}",
      'data' => [
        'type' => 'workflow_update',
        'task_id' => $task->id(),
        'status' => $newStatus,
      ],
    ]);
  }

  public function sendMentionNotification(UserInterface $mentioned, $context) {
    $this->send($mentioned, [
      'title' => 'You were mentioned',
      'body' => $context['message'],
      'data' => [
        'type' => 'mention',
        'entity_type' => $context['entity_type'],
        'entity_id' => $context['entity_id'],
      ],
    ]);
  }
}
```

---

## Development Timeline

| Phase | Duration | Deliverables |
|-------|----------|--------------|
| **Phase 1: API Setup** | 1-2 weeks | JSON:API, GraphQL, OAuth configured |
| **Phase 2: Push Notifications** | 1 week | Firebase integration, device registration |
| **Phase 3: Mobile MVP** | 4-6 weeks | Core screens (Dashboard, Tasks, Groups) |
| **Phase 4: Full Features** | 4-6 weeks | All screens, offline support |
| **Phase 5: Polish & Launch** | 2 weeks | Testing, app store submission |

**Total: 2-4 months** (vs 9-12 months for full rebuild)

---

## Drupal Modules to Install

### Required

```bash
# Core API
ddev composer require drupal/jsonapi_extras drupal/simple_oauth

# Push Notifications
ddev composer require drupal/firebase

# Enable modules
ddev drush en jsonapi jsonapi_extras simple_oauth firebase -y
```

### Optional (Enhanced Features)

```bash
# Real-time updates
ddev composer require drupal/mercure  # Server-sent events

# API documentation
ddev composer require drupal/openapi drupal/openapi_ui_swagger

# GraphQL enhancements (already installed)
ddev drush en graphql graphql_core -y
```

---

## Security Considerations

### API Security Checklist

- [ ] **HTTPS only** - Never expose API over HTTP
- [ ] **Token expiration** - Short-lived access tokens (1 hour)
- [ ] **Refresh tokens** - Longer-lived, stored securely
- [ ] **CORS** - Restrict to known origins in production
- [ ] **Rate limiting** - Prevent abuse
- [ ] **Input validation** - Sanitize all inputs
- [ ] **Permission checks** - Respect Drupal's access controls

### Mobile App Security

- [ ] **Secure storage** - Use Keychain (iOS) / Keystore (Android)
- [ ] **Certificate pinning** - Prevent MITM attacks
- [ ] **No secrets in code** - Use environment variables
- [ ] **Biometric auth** - Optional fingerprint/face unlock

---

## Offline Support Strategy

### Approach: Cache-First with Background Sync

```dart
// Flutter example with offline support
class OfflineAwareApi {
  final Box<Task> _taskCache;
  final AvcApi _api;

  Future<List<Task>> getTasks() async {
    try {
      // Try network first
      final tasks = await _api.getMyTasks();

      // Cache results
      await _taskCache.clear();
      await _taskCache.addAll(tasks);

      return tasks;
    } catch (e) {
      // Return cached data if offline
      return _taskCache.values.toList();
    }
  }

  Future<void> updateTaskOffline(String taskId, String status) async {
    // Queue update for later sync
    await _pendingUpdates.add({
      'taskId': taskId,
      'status': status,
      'timestamp': DateTime.now().toIso8601String(),
    });

    // Update local cache
    final task = _taskCache.get(taskId);
    task?.status = status;
    await _taskCache.put(taskId, task!);
  }

  Future<void> syncPendingUpdates() async {
    final updates = _pendingUpdates.values.toList();
    for (final update in updates) {
      try {
        await _api.updateTask(update['taskId'], update['status']);
        await _pendingUpdates.delete(update.key);
      } catch (e) {
        // Keep in queue for retry
      }
    }
  }
}
```

---

## Comparison: Hybrid vs Full Rebuild

| Aspect | Hybrid (Drupal + Mobile) | Full Rebuild (Django/FastAPI) |
|--------|--------------------------|-------------------------------|
| **Time to first mobile screen** | 2-3 weeks | 2-3 months |
| **Backend features working** | Day 1 | Months |
| **Risk of bugs** | Low (proven backend) | High (new code) |
| **Team skills** | Mobile dev only | Full-stack Python + Mobile |
| **Long-term maintenance** | Two systems | One Python system |
| **Performance** | Good (Drupal is mature) | Potentially better |
| **Vendor lock-in** | Drupal ecosystem | Django/Python ecosystem |

---

## Recommended Mobile Framework for Hybrid

### Flutter (Recommended)

**Why Flutter for Drupal hybrid:**
1. Excellent `json_api` package for Drupal JSON:API
2. `graphql_flutter` for GraphQL queries
3. Great performance (compiled to native)
4. Single codebase for iOS + Android
5. Good documentation for Drupal integration

### React Native (Alternative)

**Why React Native:**
1. JavaScript - more developers available
2. Expo simplifies development
3. Good Apollo Client for GraphQL
4. Larger ecosystem

### Flet (Python - Simplified Only)

**Why Flet for simplified hybrid:**
1. Python-only development
2. Works with `gql` library for GraphQL
3. Best if team only knows Python
4. Trade-off: Less mature, fewer features

---

## Next Steps

1. **Enable API modules** on existing AVC site
2. **Test endpoints** with Postman/Insomnia
3. **Choose mobile framework** (Flutter recommended)
4. **Build authentication flow** first
5. **Create MVP with 3-4 screens** (Dashboard, Tasks, Profile)
6. **Add push notifications**
7. **Iterate based on user feedback**

---

## Sources

### Drupal API Documentation
- [JSON:API Module](https://www.drupal.org/docs/core-modules-and-themes/core-modules/jsonapi-module)
- [Simple OAuth](https://www.drupal.org/project/simple_oauth)
- [GraphQL Module](https://www.drupal.org/project/graphql)
- [Firebase Push Notifications](https://www.drupal.org/project/firebase)

### Mobile Framework Integration
- [Drupal + Flutter Guide](https://gole.ms/guidance/drupal-and-flutter-native-mobile-app-experiences-your-audience)
- [Drupal JSON:API + Flutter](https://medium.com/@devbisht/drupal-json-api-and-flutter-158f67d77654)
- [React Native + Drupal](https://www.hook42.com/blog/beginners-quest-exploring-react-native-drupal)

### Authentication
- [JWT Authentication](https://www.drupal.org/docs/contributed-modules/api-authentication/jwt-authentication)
- [Decoupled Drupal Auth with JWT](https://preston.so/writing/decoupled-drupal-authentication-with-json-web-tokens/)
