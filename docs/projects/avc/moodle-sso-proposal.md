# AVC-Moodle Integration Proposal
**Phased Implementation Plan for SSO, Role Management, and Data Synchronization**

**Version:** 1.0
**Date:** 2026-01-13
**Status:** PROPOSED

---

## Executive Summary

This proposal outlines multiple approaches and implementation phases for integrating an AVC (Autonomous Village Collaborative) OpenSocial/Drupal site with Moodle LMS. The integration will enable:

1. **Single Sign-On (SSO)** - AVC members auto-login to Moodle using AVC credentials
2. **Role Synchronization** - AVC formation guilds manage Moodle roles and permissions
3. **Universal Member Access** - Any AVC member can access Moodle as a member
4. **Bi-directional Data Flow** - Badges and course completion data accessible to AVC site

**Current State:** A complete OAuth2/OpenID Connect SSO solution exists in `~/opensocial-moodle-sso-integration` (22GB, production-ready, v1.0.0).

---

## Integration Approach Comparison

### 1. OAuth2 + OpenID Connect (Existing Solution)
**Status:** ✅ Production-ready implementation exists

**Strengths:**
- Industry-standard protocol (RFC 6749, OpenID Connect 1.0)
- No shared database or session coupling required
- Works across different domains
- Comprehensive existing implementation (1500-line installer)
- Token-based security (2048-bit RSA)
- 5-minute token lifetime minimizes security risk
- Well-documented with 7+ guides

**Weaknesses:**
- No built-in role synchronization beyond initial login
- OAuth2 user data only syncs on first login (not continuous)
- Requires HTTPS and proper certificate management
- More complex troubleshooting than session-based methods

**Best For:** Production deployments, security-conscious environments, cross-domain setups

**Current Implementation:**
- Drupal module: `opensocial_oauth_provider/` (extends Simple OAuth)
- Moodle plugin: `moodle_opensocial_auth/` (auth plugin for Moodle 4.0+)
- Endpoints: `/oauth/authorize`, `/oauth/token`, `/oauth/userinfo`
- User mapping: email, username, first/last name, profile picture
- Tested across 28 OpenSocial + 14 Moodle installations

---

### 2. SAML 2.0 SSO
**Status:** Alternative approach, requires new development

**Strengths:**
- Enterprise-grade security standard
- Better support for role/attribute synchronization
- Can sync user data on every login (not just first)
- Built-in logout propagation
- Richer attribute mapping capabilities

**Weaknesses:**
- More complex certificate management
- Requires SAML Identity Provider module for Drupal
- Steeper learning curve
- More XML configuration files

**Best For:** Enterprise deployments needing continuous attribute sync, complex role mapping

**Required Components:**
- Drupal: SAML IDP 2.0 module
- Moodle: SAML 2.0 authentication plugin (core)
- SSL certificates for signing assertions

---

### 3. Drupal Services (Session-Based SSO)
**Status:** Alternative approach, simpler but more coupled

**Strengths:**
- Simpler to configure than OAuth2/SAML
- Direct REST API communication
- Real-time user synchronization
- Lighter weight than token-based methods

**Weaknesses:**
- Requires shared cookie domain (e.g., avc.example.com, moodle.example.com)
- Less secure than token-based methods
- Tighter coupling between systems
- Session management complexity

**Best For:** Single-domain deployments, simpler requirements, rapid prototyping

**Required Components:**
- Drupal: Services module + REST Server
- Moodle: Drupal Services authentication plugin

---

### 4. LTI 1.3 (Learning Tools Interoperability)
**Status:** Complementary to SSO, not replacement

**Strengths:**
- Standard for educational tool integration
- Deep linking capabilities (embed Moodle content in AVC)
- Grade passback to external system
- Tool-specific security model

**Weaknesses:**
- Not designed as primary SSO method
- Typically used for content embedding, not full access
- More complex than basic SSO
- Better suited for launching specific courses/activities

**Best For:** Embedding Moodle courses within AVC pages, grade synchronization

**Use Case Example:** AVC formation guild page embeds specific Moodle course, users launch with single click

---

## Integration Requirements Analysis

### Requirement 1: SSO (Auto-Login/Login)
**Goal:** AVC members click a link and are automatically logged into Moodle

**Solution Approaches:**
- **Primary:** OAuth2 (existing implementation) ✅
- **Alternative:** SAML 2.0 (better attribute sync)
- **Fallback:** Drupal Services (simpler, same domain required)

**Decision Criteria:**
- Do sites share domain? → Yes: Consider Drupal Services; No: OAuth2/SAML
- Need continuous user data sync? → Yes: SAML; No: OAuth2
- Security requirements? → High: OAuth2/SAML; Medium: Drupal Services

---

### Requirement 2: Role Synchronization (Formation Guilds → Moodle Roles)
**Challenge:** OAuth2 has limited role sync capabilities (only on first login)

**AVC Context:**
- Formation guilds = Drupal organic groups or similar
- Need to map guild roles (admin, teacher, facilitator) to Moodle roles (teacher, editingteacher, manager)
- Roles change over time (user promoted in guild → Moodle role should update)

**Solution Architecture:**

#### Option A: OAuth2 + Custom Sync Service (Recommended)
```
┌─────────────────┐           ┌──────────────────┐
│   AVC Drupal    │           │  Moodle LMS      │
│                 │           │                  │
│  Guild System   │◄─────────►│  Cohorts         │
│  (Groups)       │  Sync     │  (Membership)    │
│                 │  Service  │                  │
│  Guild Roles    │◄─────────►│  Roles           │
│  (Permissions)  │           │  (Permissions)   │
└─────────────────┘           └──────────────────┘
         │                             ▲
         │                             │
         │      OAuth2 SSO Login       │
         └─────────────────────────────┘
```

**Components:**
1. **OAuth2 for SSO** (existing) - Handles authentication
2. **Moodle Web Services API** - Exposes cohort/role management
3. **AVC Sync Module** (custom) - Drupal module that:
   - Monitors guild membership changes (hook_group_membership_insert/update/delete)
   - Calls Moodle Web Services to update cohorts/roles
   - Runs periodic sync (cron) to ensure consistency
4. **Moodle Cohort-to-Role Plugin** - Auto-assigns roles based on cohort membership

**User Flow:**
1. User joins "Web Development Guild" in AVC as "Facilitator"
2. AVC sync module detects change
3. Calls Moodle Web Services: add user to "Web Dev Cohort"
4. Moodle cohort-role plugin assigns "Teacher" role automatically
5. User logs in via OAuth2 → sees teacher permissions

**Advantages:**
- Decoupled: OAuth2 handles auth, Web Services handle role sync
- Real-time updates when guild membership changes
- Leverages existing Moodle cohort system
- Existing plugin: [Cohort role synchronization](https://moodle.org/plugins/local_cohortrole)

**Disadvantages:**
- Requires custom development (AVC sync module)
- Two-way complexity (keep systems in sync)
- Need API token management

#### Option B: SAML 2.0 with Attribute Mapping
```
SAML Assertion includes:
- sub: user_id
- email: user@avc.org
- groups: ["web-dev-guild", "permaculture-guild"]
- roles: ["web-dev:facilitator", "permaculture:student"]

Moodle maps attributes to cohorts/roles on every login
```

**Advantages:**
- Syncs on every login (not just first)
- Standard SAML attribute mapping
- No separate sync service needed
- Richer attribute support than OAuth2

**Disadvantages:**
- Requires SAML implementation (more complex than OAuth2)
- Still needs guild → role mapping logic
- Only syncs when user logs in (not instant)

#### Option C: LDAP + Cohort Sync
**Not Recommended** - Requires running LDAP server, added complexity

---

### Requirement 3: Universal Member Access
**Goal:** Any AVC member can login to Moodle as "member" role

**Solution:** Default role assignment in OAuth2/SAML configuration

**Moodle Configuration:**
```
Authentication Plugin Settings:
├─ OAuth2 / SAML Settings
│  ├─ Default role: Student (or custom "Member" role)
│  ├─ Auto-create users: Yes
│  └─ Update user data: Yes (on login)
```

**Implementation:**
1. Create custom "Member" role in Moodle (if "Student" insufficient)
2. Configure OAuth2/SAML to auto-assign this role on first login
3. All AVC members get this baseline access
4. Formation guild members get additional roles via sync system

**Already Supported:** Existing OAuth2 implementation supports this out-of-box

---

### Requirement 4: Badge & Course Completion Data → AVC
**Goal:** Display user badges and course completions on AVC profile/guild pages

**Challenge:** Moodle → Drupal data flow (reverse direction from SSO)

**Solution Architecture:**

#### Option A: Moodle Web Services API (Pull Model)
```
┌─────────────────┐           ┌──────────────────┐
│   AVC Drupal    │           │  Moodle LMS      │
│                 │           │                  │
│  User Profile   │──Request──►│ Web Services    │
│  Page           │           │ API              │
│                 │◄──JSON────┤                  │
│  Guild Stats    │           │ - Badges         │
│  Dashboard      │──Request──►│ - Completions   │
│                 │◄──JSON────┤ - Grades         │
└─────────────────┘           └──────────────────┘
```

**Moodle Web Services Functions:**
- `core_badges_get_user_badges` - Retrieve user badges
- `core_completion_get_course_completion_status` - Course completion
- `core_course_get_courses_by_field` - Course details
- `gradereport_user_get_grade_items` - User grades

**AVC Implementation:**
1. **Drupal Module: "AVC Moodle Data Connector"**
   - Stores Moodle Web Services endpoint + token
   - Provides API wrapper functions
   - Implements caching (15-60 minute TTL)

2. **User Profile Integration:**
   ```php
   // Display badges on AVC user profile
   $badges = avc_moodle_get_user_badges($user->id);
   foreach ($badges as $badge) {
     render_badge($badge->name, $badge->imageurl);
   }
   ```

3. **Guild Dashboard Integration:**
   ```php
   // Show guild members' course completions
   $members = get_guild_members($guild_id);
   foreach ($members as $member) {
     $completions = avc_moodle_get_completions($member->id);
     display_member_progress($member, $completions);
   }
   ```

**Advantages:**
- Real-time data (with caching)
- Full control over display
- Leverages official Moodle APIs
- No database coupling

**Disadvantages:**
- Requires API token management
- Network latency (mitigated by caching)
- Need to handle API errors gracefully

#### Option B: Webhooks / Event Notifications (Push Model)
```
Moodle Event Triggers:
├─ Badge Awarded → POST to AVC webhook
├─ Course Completed → POST to AVC webhook
└─ Grade Updated → POST to AVC webhook

AVC receives notifications and stores locally
```

**Moodle Plugin: Event Notifier**
- Hooks into Moodle events system
- Sends HTTP POST to AVC endpoint when events fire
- AVC stores data in local database for fast display

**Advantages:**
- Near real-time updates
- No polling/caching needed
- Data stored locally in AVC

**Disadvantages:**
- Requires custom Moodle plugin
- Network reliability concerns (need retry logic)
- Data duplication between systems
- Webhook security (HMAC signatures)

#### Option C: Open Badges 2.0 Standard
**For badges only** - Use Open Badges backpack

```
Moodle → Open Badges Backpack (Badgr.com, etc.)
                ↓
        AVC displays from backpack
```

**Advantages:**
- Industry standard
- User owns badges (portable across platforms)
- No custom integration needed

**Disadvantages:**
- Only works for badges (not course completion)
- Requires external service
- User must claim badges to backpack

---

## Recommended Phased Implementation

### Phase 1: SSO Foundation (Weeks 1-2)
**Goal:** AVC members can login to Moodle with AVC credentials

**Approach:** Deploy existing OAuth2 solution

**Tasks:**
1. Review existing implementation in `~/opensocial-moodle-sso-integration`
2. Adapt installation script for AVC + Moodle instances
3. Deploy OAuth provider module to AVC Drupal
4. Deploy OAuth authentication plugin to Moodle
5. Configure OAuth2 client (Client ID, Secret, key paths)
6. Test SSO flow: AVC login → Moodle access
7. Configure default "Member" role for all AVC users

**Deliverables:**
- ✅ Working SSO from AVC to Moodle
- ✅ All AVC members can access Moodle
- ✅ User profile data synced (email, name, picture)
- ✅ Documentation for troubleshooting

**Success Criteria:**
- [ ] 100 test logins successful
- [ ] Token expiration handled correctly
- [ ] User data mapping verified
- [ ] HTTPS working properly

**Effort:** 2-3 days (mostly configuration + testing)

---

### Phase 2: Basic Role Synchronization (Weeks 3-4)
**Goal:** Formation guild roles map to Moodle roles

**Approach:** Implement Option A (OAuth2 + Custom Sync Service)

**Tasks:**

#### 2.1: Define Mapping Rules
```yaml
# guild_role_mapping.yml
mappings:
  web-dev-guild:
    facilitator: teacher
    mentor: teacher
    student: student

  permaculture-guild:
    guild-leader: editingteacher
    facilitator: teacher
    apprentice: student

  default:
    member: student
```

#### 2.2: Develop AVC Sync Module (Drupal)
**Module:** `avc_moodle_sync`

**Files:**
```
avc_moodle_sync/
├── avc_moodle_sync.info.yml
├── avc_moodle_sync.module
├── avc_moodle_sync.install
├── avc_moodle_sync.routing.yml
├── config/
│   └── install/
│       └── avc_moodle_sync.settings.yml
└── src/
    ├── MoodleApiClient.php          # Web Services wrapper
    ├── RoleSyncService.php           # Guild → Moodle sync logic
    └── Form/
        └── SettingsForm.php          # Admin config form
```

**Functionality:**
1. **Settings Form:**
   - Moodle URL
   - Web Services API token
   - Role mapping configuration
   - Sync frequency (cron)

2. **MoodleApiClient class:**
   ```php
   class MoodleApiClient {
     public function addUserToCohort($userid, $cohortid);
     public function removeUserFromCohort($userid, $cohortid);
     public function assignRole($userid, $roleid, $contextid);
     public function getCohorts();
   }
   ```

3. **RoleSyncService class:**
   ```php
   class RoleSyncService {
     public function syncUserRoles($drupal_uid);
     public function syncGuildRoles($guild_id);
     public function fullSync(); // Cron job
   }
   ```

4. **Hooks:**
   ```php
   // When user joins/leaves guild
   hook_group_membership_insert($group_membership);
   hook_group_membership_update($group_membership);
   hook_group_membership_delete($group_membership);

   // When guild role changes
   hook_group_role_grant($role_grant);
   hook_group_role_revoke($role_revoke);
   ```

#### 2.3: Configure Moodle Web Services
1. Enable Web Services (Site administration → Advanced features)
2. Enable REST protocol
3. Create service: "AVC Guild Sync"
4. Add functions:
   - `core_cohort_add_cohort_members`
   - `core_cohort_delete_cohort_members`
   - `core_role_assign_roles`
   - `core_role_unassign_roles`
5. Create service user + token
6. Grant permissions to service user

#### 2.4: Install Moodle Cohort-Role Plugin
- Plugin: [local_cohortrole](https://moodle.org/plugins/local_cohortrole)
- Configure automatic role assignment based on cohort
- Create cohorts matching guild structure

#### 2.5: Testing
- [ ] User joins guild → assigned to Moodle cohort → gets role
- [ ] User leaves guild → removed from cohort → loses role
- [ ] User role upgraded in guild → Moodle role updates
- [ ] Cron sync recovers from any manual changes

**Deliverables:**
- ✅ AVC Drupal module for guild sync
- ✅ Moodle Web Services configured
- ✅ Cohort-role mapping active
- ✅ Real-time and cron sync working

**Success Criteria:**
- [ ] Role sync < 5 seconds for real-time updates
- [ ] Cron sync runs successfully every hour
- [ ] 100% accuracy in role mapping tests
- [ ] Error logging and admin notifications

**Effort:** 1-2 weeks development + testing

---

### Phase 3: Badge & Course Completion Display (Weeks 5-6)
**Goal:** Show Moodle achievements on AVC profiles and guild pages

**Approach:** Implement Option A (Web Services Pull Model with caching)

**Tasks:**

#### 3.1: Extend AVC Moodle Module
**New Components:**
```
avc_moodle_sync/src/
├── MoodleDataService.php             # Badge/completion fetching
├── CacheManager.php                  # Cache badge/completion data
└── Render/
    ├── BadgeRenderer.php             # Badge display
    └── CompletionRenderer.php        # Progress display
```

**MoodleDataService class:**
```php
class MoodleDataService {
  public function getUserBadges($drupal_uid, $use_cache = true);
  public function getCourseCompletions($drupal_uid, $use_cache = true);
  public function getGuildMemberStats($guild_id);
  public function invalidateCache($drupal_uid);
}
```

#### 3.2: User Profile Integration
**Display on AVC user profile:**
```
┌─────────────────────────────────────┐
│  John's Profile                      │
├─────────────────────────────────────┤
│  Bio, Avatar, etc.                   │
│                                      │
│  📚 Learning Achievements            │
│  ┌───────────────────────────────┐  │
│  │ 🏆 Badges Earned (3)          │  │
│  │ [Badge1] [Badge2] [Badge3]    │  │
│  └───────────────────────────────┘  │
│                                      │
│  ┌───────────────────────────────┐  │
│  │ ✅ Courses Completed (2/5)    │  │
│  │ ▓▓▓▓▓░░░░░ 40%                │  │
│  │                                │  │
│  │ ✓ Web Development Basics       │  │
│  │ ✓ Permaculture Design          │  │
│  │ ○ Advanced JavaScript          │  │
│  └───────────────────────────────┘  │
└─────────────────────────────────────┘
```

**Implementation:**
```php
// In user profile template
$badges = \Drupal::service('avc_moodle_sync.data_service')
  ->getUserBadges($user->id());

$completions = \Drupal::service('avc_moodle_sync.data_service')
  ->getCourseCompletions($user->id());

echo \Drupal::service('avc_moodle_sync.badge_renderer')
  ->render($badges);

echo \Drupal::service('avc_moodle_sync.completion_renderer')
  ->render($completions);
```

#### 3.3: Guild Dashboard Integration
**Display on formation guild pages:**
```
┌─────────────────────────────────────┐
│  Web Development Guild              │
├─────────────────────────────────────┤
│  Guild Stats                         │
│  👥 Members: 24                      │
│  📚 Total Completions: 47            │
│  🏆 Total Badges: 89                 │
│                                      │
│  Top Learners                        │
│  1. Alice (12 badges, 8 courses)     │
│  2. Bob (10 badges, 6 courses)       │
│  3. Carol (8 badges, 5 courses)      │
│                                      │
│  📊 Guild Progress                   │
│  Beginner JavaScript:  ▓▓▓▓▓▓░░░░ 60%│
│  React Fundamentals:   ▓▓▓░░░░░░░ 30%│
│  Node.js Basics:       ▓▓▓▓▓▓▓▓░░ 80%│
└─────────────────────────────────────┘
```

**Implementation:**
```php
// Guild page controller
$stats = \Drupal::service('avc_moodle_sync.data_service')
  ->getGuildMemberStats($guild_id);

// Returns:
// {
//   total_members: 24,
//   total_badges: 89,
//   total_completions: 47,
//   top_learners: [...],
//   course_progress: [...]
// }
```

#### 3.4: Caching Strategy
```php
// Cache configuration
'avc_moodle_sync.badges' => [
  'backend' => 'cache.backend.database',
  'expire' => 3600, // 1 hour
],

'avc_moodle_sync.completions' => [
  'backend' => 'cache.backend.database',
  'expire' => 1800, // 30 minutes
],
```

**Cache Invalidation:**
- Manual: Admin can clear cache
- Webhook: If Phase 4 implemented (push notifications)
- TTL: Auto-expire after time limit

#### 3.5: Testing
- [ ] Badges display correctly on profile
- [ ] Completions show accurate progress
- [ ] Guild stats aggregate properly
- [ ] Cache reduces API calls (verify logs)
- [ ] Graceful handling of Moodle API errors

**Deliverables:**
- ✅ Badge display on user profiles
- ✅ Course completion display
- ✅ Guild dashboard with learning stats
- ✅ Caching system operational
- ✅ Error handling and fallbacks

**Success Criteria:**
- [ ] Page load < 2 seconds with cache
- [ ] API call reduction > 90% due to caching
- [ ] Visual design matches AVC theme
- [ ] Mobile responsive

**Effort:** 1 week development + testing

---

### Phase 4: Enhanced Features (Weeks 7-8+)
**Goal:** Production hardening and advanced features

**Optional Enhancements:**

#### 4.1: Real-Time Updates (Webhooks)
- Develop Moodle event notifier plugin
- AVC receives instant badge/completion notifications
- Reduces cache latency to near-zero

#### 4.2: Course Enrollment Integration
- AVC guild admins can enroll members in Moodle courses from AVC
- Use Moodle Web Services: `enrol_manual_enrol_users`

#### 4.3: Grade Synchronization
- Display Moodle grades on AVC profiles
- Could influence AVC reputation/karma systems

#### 4.4: LTI Deep Linking
- Embed Moodle courses directly in AVC guild pages
- Seamless launch from AVC to specific Moodle content

#### 4.5: Open Badges Integration
- Export Moodle badges to Badgr/Open Badges backpack
- AVC displays badges from backpack (portable across platforms)

#### 4.6: Analytics Dashboard
- AVC admin dashboard showing cross-guild learning analytics
- Most popular courses, completion rates, badge distributions

#### 4.7: SAML Migration (Optional)
- Migrate from OAuth2 to SAML for continuous attribute sync
- Only if real-time role sync proves critical

**Deliverables:**
- Custom features based on priority
- Performance optimization
- Monitoring and alerting
- Backup/recovery procedures

**Effort:** Varies by feature selection

---

## Technical Architecture Summary

### System Components
```
┌─────────────────────────────────────────────────────────────┐
│                     AVC Drupal Site                          │
│                                                              │
│  ┌──────────────────┐  ┌──────────────────┐                │
│  │ OpenSocial OAuth │  │ AVC Moodle Sync  │                │
│  │ Provider Module  │  │ Module           │                │
│  │                  │  │                  │                │
│  │ • /oauth/        │  │ • Role Sync      │                │
│  │   authorize      │  │ • Data Fetch     │                │
│  │ • /oauth/token   │  │ • Cache Mgmt     │                │
│  │ • /oauth/        │  │ • Display        │                │
│  │   userinfo       │  │   Renderers      │                │
│  └────────┬─────────┘  └────────┬─────────┘                │
│           │                     │                           │
└───────────┼─────────────────────┼───────────────────────────┘
            │                     │
            │ OAuth2 SSO          │ Web Services API
            │ (Authentication)    │ (Role Sync + Data)
            │                     │
┌───────────▼─────────────────────▼───────────────────────────┐
│                     Moodle LMS                               │
│                                                              │
│  ┌──────────────────┐  ┌──────────────────┐                │
│  │ OAuth2 Auth      │  │ Web Services     │                │
│  │ Plugin           │  │ (REST)           │                │
│  │                  │  │                  │                │
│  │ • Login Handler  │  │ • Cohort API     │                │
│  │ • User Provisio  │  │ • Role API       │                │
│  │ • Default Roles  │  │ • Badge API      │                │
│  └──────────────────┘  │ • Completion API │                │
│                        │ • Course API     │                │
│  ┌──────────────────┐  └──────────────────┘                │
│  │ Cohort Role Sync │                                       │
│  │ Plugin           │                                       │
│  │ (local_cohortrole)│                                      │
│  └──────────────────┘                                       │
│                                                              │
│  Courses, Badges, Completions, Grades                       │
└──────────────────────────────────────────────────────────────┘
```

### Data Flow Diagrams

#### SSO Authentication Flow
```
User                AVC Drupal           Moodle
 │                      │                   │
 ├─1. Visit Moodle─────┼──────────────────►│
 │                      │                   │
 │                      │◄─2. Redirect to AVC OAuth
 │                      │                   │
 ├─3. Login (if needed)►│                   │
 │                      │                   │
 │◄─4. Auth Code────────┤                   │
 │                      │                   │
 ├──────────────────────┼─5. Exchange Code─►│
 │                      │                   │
 │                      │◄─6. Access Token──┤
 │                      │                   │
 │                      │◄─7. Get User Info─┤
 │                      │                   │
 │                      ├─8. User Data─────►│
 │                      │                   │
 │◄─────────────────────┼─9. Logged In──────┤
```

#### Role Synchronization Flow
```
Guild Change         AVC Drupal           Moodle
    │                    │                   │
    ├─1. User joins guild│                   │
    │   as Facilitator   │                   │
    │                    │                   │
    │                    ├─2. Hook triggered │
    │                    │   (membership)    │
    │                    │                   │
    │                    ├─3. Lookup mapping │
    │                    │   Facilitator→    │
    │                    │   Teacher         │
    │                    │                   │
    │                    ├─4. API Call──────►│
    │                    │   addUserToCohort │
    │                    │   (Web-Dev-Guild) │
    │                    │                   │
    │                    │◄─5. Success───────┤
    │                    │                   │
    │                    │                   ├─6. Cohort-Role
    │                    │                   │   Plugin assigns
    │                    │                   │   Teacher role
    │                    │                   │
    │                    │◄─7. Confirmation──┤
```

#### Badge/Completion Data Flow
```
Profile Load         AVC Drupal           Moodle
    │                    │                   │
    ├─1. User visits own │                   │
    │   profile          │                   │
    │                    │                   │
    │                    ├─2. Check cache    │
    │                    │   (user badges)   │
    │                    │                   │
    │                    ├─3. Cache miss─────┤
    │                    │                   │
    │                    ├─4. API Call──────►│
    │                    │   getUserBadges   │
    │                    │                   │
    │                    │◄─5. Badge JSON────┤
    │                    │   [{name, image,  │
    │                    │     date}, ...]   │
    │                    │                   │
    │                    ├─6. Store cache    │
    │                    │   (1hr TTL)       │
    │                    │                   │
    │                    ├─7. Render badges  │
    │                    │                   │
    │◄─8. Profile page───┤                   │
    │   with badges      │                   │
```

---

## Security Considerations

### OAuth2 Security
- ✅ 2048-bit RSA key pairs for token signing
- ✅ 5-minute access token lifetime (minimizes exposure)
- ✅ HTTPS required for all OAuth communication
- ✅ Client secret protection (600 permissions on keys)
- ✅ State parameter prevents CSRF attacks

### Web Services API Security
- 🔒 Token-based authentication (not username/password)
- 🔒 Service user with minimal required permissions
- 🔒 IP whitelisting (optional, for extra security)
- 🔒 Rate limiting on API calls
- 🔒 Audit logging of all API actions

### Data Privacy
- 📋 Only sync necessary user data (principle of least privilege)
- 📋 User consent for data sharing (OAuth grant screen)
- 📋 Data retention policies (cache TTL limits)
- 📋 GDPR compliance: user can revoke OAuth token

### Operational Security
- 🛡️ Secrets management (credentials not in git)
- 🛡️ Regular security updates (Drupal + Moodle)
- 🛡️ Monitoring and alerting (failed auth attempts)
- 🛡️ Backup and disaster recovery

---

## Risk Assessment

### High Risk
❌ **OAuth2 token compromise** → Attacker gains Moodle access
- **Mitigation:** Short token lifetime (5 min), HTTPS only, secure key storage

❌ **Web Services token leak** → Attacker can manipulate roles/data
- **Mitigation:** Secure token storage, IP whitelisting, audit logging

### Medium Risk
⚠️ **Role sync failures** → Users have wrong permissions
- **Mitigation:** Cron reconciliation, error notifications, audit trail

⚠️ **API rate limits** → Service degradation
- **Mitigation:** Caching, batch operations, backoff/retry logic

⚠️ **Data inconsistency** → AVC/Moodle out of sync
- **Mitigation:** Regular full sync, conflict resolution strategy

### Low Risk
✓ **Cache staleness** → Slightly outdated badge/completion data
- **Mitigation:** Reasonable TTL (30-60 min), manual refresh option

✓ **Network failures** → Temporary unavailability
- **Mitigation:** Graceful degradation, error messages, retry mechanisms

---

## Testing Strategy

### Phase 1 Testing (SSO)
- [ ] Unit tests: Token generation/validation
- [ ] Integration tests: Full OAuth flow
- [ ] Load tests: 100 concurrent logins
- [ ] Security tests: Token expiration, HTTPS enforcement
- [ ] User acceptance: 10 real users test SSO

### Phase 2 Testing (Role Sync)
- [ ] Unit tests: Role mapping logic
- [ ] Integration tests: Guild join/leave → Moodle cohort changes
- [ ] Edge cases: User in multiple guilds, role changes
- [ ] Performance: Sync 1000 users in < 5 minutes
- [ ] Audit: Verify all role changes logged

### Phase 3 Testing (Data Display)
- [ ] Unit tests: Badge/completion rendering
- [ ] Integration tests: API calls, cache behavior
- [ ] UI tests: Display accuracy across devices
- [ ] Performance: Page load < 2 seconds
- [ ] Accessibility: WCAG 2.1 AA compliance

### Phase 4 Testing (Production)
- [ ] Penetration testing: Security vulnerabilities
- [ ] Disaster recovery: Backup/restore procedures
- [ ] Scalability: Handle 10x user growth
- [ ] Monitoring: Alerts fire correctly
- [ ] Documentation: New admins can troubleshoot

---

## Resource Requirements

### Development Team
- **Drupal Developer:** 2-3 weeks (AVC modules)
- **Moodle Administrator:** 1 week (configuration)
- **DevOps Engineer:** 1 week (deployment, monitoring)
- **QA Tester:** 1 week (testing across phases)
- **Total:** ~4-6 person-weeks

### Infrastructure
- **HTTPS Certificates:** Required for OAuth2 (Let's Encrypt free)
- **Database:** No additional (uses existing Drupal/Moodle DBs)
- **Caching:** Drupal database cache (or Redis if high performance needed)
- **Monitoring:** Logs aggregation (optional: ELK stack, Grafana)

### Third-Party Services (Optional)
- **Open Badges Backpack:** Badgr.com (free tier available)
- **CDN:** For badge images (optional optimization)

---

## Success Metrics

### Phase 1 (SSO)
- ✅ 95%+ successful login rate
- ✅ < 3 second login flow completion
- ✅ Zero security incidents in first month
- ✅ User satisfaction > 4/5 stars

### Phase 2 (Role Sync)
- ✅ 100% role mapping accuracy
- ✅ < 5 second real-time sync
- ✅ < 1 hour cron sync completion
- ✅ Zero permission escalation bugs

### Phase 3 (Data Display)
- ✅ 100% badge/completion display accuracy
- ✅ < 2 second page load time (cached)
- ✅ 90%+ cache hit rate
- ✅ User engagement with learning stats

### Overall
- ✅ Reduced support tickets for "login issues"
- ✅ Increased Moodle course enrollment from AVC
- ✅ Formation guild admins actively use role management
- ✅ System uptime > 99.5%

---

## Decision Matrix

| Requirement | OAuth2 (Existing) | SAML 2.0 | Drupal Services | LTI 1.3 |
|------------|-------------------|----------|-----------------|---------|
| **SSO (Login)** | ✅ Excellent | ✅ Excellent | ✅ Good | ⚠️ Limited |
| **Role Sync** | ⚠️ Requires custom sync | ✅ Better built-in | ⚠️ Requires custom | ❌ Not designed for this |
| **Data Sync (Badges)** | ⚠️ Requires Web Services | ⚠️ Requires Web Services | ⚠️ Requires Web Services | ✅ Grade passback only |
| **Security** | ✅ Excellent | ✅ Excellent | ⚠️ Medium | ✅ Good |
| **Complexity** | ✅ Medium (existing impl) | ⚠️ High | ✅ Low | ⚠️ Medium |
| **Cross-Domain** | ✅ Yes | ✅ Yes | ❌ Same domain required | ✅ Yes |
| **Maturity** | ✅ Production-ready code | ⚠️ Needs development | ⚠️ Needs development | ⚠️ Needs development |
| **Cost** | ✅ Free (OSS) | ✅ Free (OSS) | ✅ Free (OSS) | ✅ Free (OSS) |

**Recommendation:**
- **Primary:** OAuth2 (existing implementation) + Web Services for role/data sync
- **Alternative:** SAML 2.0 if continuous attribute sync proves critical
- **Complement:** LTI 1.3 for course embedding (Phase 4 optional)

---

## Migration Path (If Upgrading from Existing System)

### If Currently Using No Integration
1. ✅ Deploy Phase 1 (SSO) immediately
2. ✅ Gradually add Phases 2-3 as features stabilize
3. ✅ Train guild admins on role management

### If Currently Using Manual Enrollment
1. ⚠️ Export existing Moodle users
2. ⚠️ Match to AVC users (by email)
3. ⚠️ Assign to appropriate cohorts based on guilds
4. ⚠️ Enable OAuth2 SSO (manual enrollment still works)
5. ⚠️ Gradually transition users to SSO
6. ✅ Deprecate manual enrollment after 90 days

### If Currently Using LDAP
1. ⚠️ Run LDAP and OAuth2 in parallel
2. ⚠️ Migrate users cohort-by-cohort
3. ⚠️ Verify role mappings preserved
4. ✅ Deprecate LDAP after successful migration

---

## Open Questions

### Technical
1. **Guild Structure in AVC:** What Drupal module manages guilds? (Organic Groups? Custom entities?)
2. **Moodle Version:** Confirmed 4.0+? Any customizations that might conflict?
3. **Domain Setup:** Are sites on same domain (e.g., avc.org, moodle.avc.org) or different?
4. **Existing Moodle Users:** Should existing Moodle accounts be merged with AVC accounts?
5. **Role Granularity:** How many distinct roles in AVC guilds? (Need 1:1 mapping to Moodle roles)

### Functional
6. **Role Hierarchy:** Can users have multiple guild roles simultaneously?
7. **Guest Access:** Should non-AVC members be able to access Moodle courses? (Public courses)
8. **Badge Display Priority:** Should all badges show, or only recent/featured?
9. **Course Catalog:** Should AVC display Moodle course catalog? (Browse/search from AVC)
10. **Enrollment Workflow:** Can guild admins enroll members in courses from AVC, or only from Moodle?

### Organizational
11. **Timeline Pressure:** Is there a hard deadline for launch?
12. **Pilot Group:** Which guild should test first? (Small, tech-savvy group recommended)
13. **Support Resources:** Who will handle day-to-day support questions?
14. **Maintenance Window:** When can system downtime occur for deployments?
15. **Success Definition:** How will you measure success beyond technical metrics?

---

## Next Steps

### Immediate Actions
1. **Review Existing Code:** Audit `~/opensocial-moodle-sso-integration` for AVC compatibility
2. **Answer Open Questions:** Clarify technical requirements and constraints
3. **Stakeholder Approval:** Present this proposal to AVC + Moodle admins
4. **Environment Setup:** Prepare dev/staging environments for testing
5. **Timeline Planning:** Map phases to calendar with milestones

### Decision Points
- [ ] **Choose SSO Method:** OAuth2 (recommended) or SAML 2.0?
- [ ] **Choose Role Sync Approach:** Custom sync service (recommended) or SAML attributes?
- [ ] **Choose Data Display:** Web Services pull (recommended) or webhooks push?
- [ ] **Phase 4 Scope:** Which optional features are priorities?

### Risks to Monitor
- ⚠️ Existing Moodle customizations conflicting with OAuth plugin
- ⚠️ AVC guild structure incompatible with assumptions
- ⚠️ Performance issues with large user base (100k+ users)
- ⚠️ HTTPS certificate/domain configuration problems

---

## Appendix: Technology References

### OAuth2 & OpenID Connect
- [OAuth 2.0 RFC 6749](https://datatracker.ietf.org/doc/html/rfc6749)
- [OpenID Connect Core 1.0](https://openid.net/specs/openid-connect-core-1_0.html)
- [Drupal Simple OAuth Module](https://www.drupal.org/project/simple_oauth)

### SAML 2.0
- [SAML IDP 2.0 Single Sign On (Drupal)](https://www.drupal.org/docs/contributed-modules/saml-idp-20-single-sign-on-sso-saml-identity-provider)
- [Moodle SAML Authentication](https://docs.moodle.org/en/SAML_2.0_authentication)

### Moodle Web Services
- [Moodle Web Services API Documentation](https://docs.moodle.org/dev/Web_service_API_functions)
- [Badges API](https://moodledev.io/docs/5.2/apis/subsystems/badges)
- [Using Web Services in Moodle](https://supportus.moodle.com/support/solutions/articles/80001016973)

### Moodle Plugins
- [Drupal Services Authentication](https://moodle.org/plugins/auth_drupalservices)
- [Cohort Role Synchronization](https://moodle.org/plugins/local_cohortrole)
- [LDAP Syncing Scripts](https://moodle.org/plugins/local_ldap)

### Integration Examples
- [Drupal Moodle Integration - Knackforge](https://knackforge.com/knowledge-center/drupal-moodle-integration/)
- [Moodle SSO Authentication Methods - ScholarLMS](https://www.scholarlms.com/moodle-sso-authentication-methods-for-lms-administrators/)

---

## Document History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-01-13 | Claude Code | Initial proposal based on investigation of existing OAuth2 implementation and research into integration methods |

---

**END OF PROPOSAL**
