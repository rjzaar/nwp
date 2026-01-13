# Proposal: AVC Error Reporting Module

**Status:** PROPOSED
**Author:** Claude Code
**Date:** 2026-01-13
**Target Version:** v0.14

## Executive Summary

Create a new Drupal custom module `avc_error_report` that adds a prominent "Report Error" button to the site navigation, allowing authenticated users to submit error reports directly to the AVC GitLab repository. The module will capture context automatically, provide a user-friendly form for additional details, and optionally record user interactions and subsequent errors for comprehensive debugging information.

## Problem Statement

Currently, when AVC users encounter errors, they must:
- Screenshot or manually copy error messages
- Find contact information for reporting
- Compose an email with context
- Wait for follow-up questions about reproduction steps

This creates friction and results in:
- Under-reporting of bugs
- Incomplete error reports lacking context
- Developer time spent gathering information
- Delayed fixes for issues

## Proposed Solution

Add an always-visible "Report Error" button that:
1. Auto-captures previous page URL
2. Provides simple form for user explanation
3. Optionally records next-page actions and errors
4. Automatically creates GitLab issues with formatted data
5. Returns confirmation with issue link

## Requirements

### Functional Requirements

1. **Navigation Button**
   - Red, prominent button in main navigation
   - Visible to all authenticated users
   - Accessible via keyboard navigation
   - Responsive on mobile devices

2. **Error Report Form**
   - Previous page address (auto-populated from HTTP_REFERER)
   - User explanation field (required, textarea)
   - Optional error URL field (if different from previous page)
   - Error message paste area (for stack traces, console output)
   - Optional "Record next actions" checkbox
   - Submit button with clear feedback

3. **Error Capture System**
   - JavaScript-based action recording
   - Console error capturing
   - Click and form submission tracking
   - 30-second recording window
   - SessionStorage for cross-page persistence

4. **GitLab Integration**
   - Create issues in AVC repo at git.nwpcode.org
   - Format issue with structured data
   - Auto-label as "bug,user-reported,automated"
   - Return issue URL to user

5. **Security & Abuse Prevention**
   - Rate limiting (5 reports per hour per user)
   - CSRF protection
   - Input validation and sanitization
   - API token protection

### Non-Functional Requirements

1. **Performance**
   - Form load time < 100ms
   - GitLab API response < 2s
   - Recording has no noticeable impact

2. **Security**
   - All inputs sanitized
   - API tokens never exposed to client
   - Rate limiting prevents abuse
   - Logging for audit trail

3. **Usability**
   - WCAG 2.1 AA accessible
   - Clear, helpful error messages
   - Success confirmation with next steps
   - Mobile-responsive design

4. **Maintainability**
   - Follows Drupal coding standards
   - Service-oriented architecture
   - Comprehensive test coverage
   - Documented code and API

## Technical Design

### Module Structure

```
sites/avc/html/modules/custom/avc_error_report/
├── avc_error_report.info.yml
├── avc_error_report.routing.yml
├── avc_error_report.links.menu.yml
├── avc_error_report.module
├── avc_error_report.permissions.yml
├── avc_error_report.libraries.yml
├── README.md
├── config/
│   └── install/
│       └── avc_error_report.settings.yml
├── src/
│   ├── Form/
│   │   ├── ErrorReportForm.php
│   │   └── ErrorReportSettingsForm.php
│   └── Service/
│       ├── GitLabApiService.php
│       ├── ErrorCaptureService.php
│       └── RateLimitService.php
├── js/
│   └── error-capture.js
├── css/
│   └── error-report-button.css
└── tests/
    └── src/
        ├── Unit/
        ├── Kernel/
        └── Functional/
```

### Core Components

#### 1. ErrorReportForm (FormBase)

**Purpose:** Main user-facing form for error reporting

**Key Methods:**
- `buildForm()` - Constructs form with auto-populated fields
- `validateForm()` - Rate limit check, input validation
- `submitForm()` - Collects data, calls GitLab API, shows confirmation

**Dependencies:**
- GitLabApiService (for issue creation)
- RateLimitService (for abuse prevention)
- Logger (for error tracking)

**Form Fields:**
- `previous_page` (textfield, disabled) - Auto from HTTP_REFERER
- `explanation` (textarea, required) - User description
- `error_url` (url, optional) - Specific error location
- `error_message` (textarea, optional) - Stack traces, console output
- `captured_data` (hidden) - JSON from JavaScript recorder
- `enable_recording` (checkbox) - Opt-in for next-page capture

#### 2. GitLabApiService

**Purpose:** Handle all GitLab API interactions

**Key Methods:**
- `createIssue(array $reportData): string` - Creates issue, returns URL
- `formatIssueTitle(array $data): string` - Generates title
- `formatIssueDescription(array $data): string` - Formats Markdown description
- `getApiToken(): string` - Retrieves token from config/secrets

**Configuration:**
- GitLab URL (default: https://git.nwpcode.org)
- Project ID (default: avc/avc)
- API token (from .secrets.yml)

**Issue Format:**
```markdown
## User-Reported Error

**Reported by:** username (ID: 123)
**Timestamp:** 2026-01-13 15:30:00

### What Happened

[User's explanation]

### Error Location

URL: https://avc.ddev.site/path/to/error

### Previous Page

https://avc.ddev.site/previous/path

### Error Message

```
[Pasted error or stack trace]
```

### Captured User Actions

- click on button#submit at 2026-01-13T15:29:45Z
- submit on form.user-form at 2026-01-13T15:29:46Z

### Console Errors

```
TypeError: Cannot read property 'foo' of undefined at script.js:123
```

### Technical Details

- **User Agent:** Mozilla/5.0...
```

#### 3. RateLimitService

**Purpose:** Prevent spam and abuse

**Implementation:**
- Uses KeyValueFactory for persistent storage
- Key format: `user_{user_id}`
- Stores array of submission timestamps
- Configurable: max submissions and time window
- Auto-cleanup of expired timestamps

**Default Limits:**
- 5 reports per user
- Within 1 hour window
- Configurable via admin UI

**Methods:**
- `checkLimit(int $userId): bool` - Returns true if under limit
- `recordSubmission(int $userId): void` - Records new submission

#### 4. JavaScript Error Capture (error-capture.js)

**Purpose:** Record user actions and errors on next page

**Workflow:**
1. User checks "Record next actions" on form
2. Sets flag in sessionStorage
3. Navigates to another page
4. JavaScript initializes capture if flag present
5. Records clicks, form submissions, console errors
6. Saves to sessionStorage after 30s or on navigation
7. Returns to error form
8. Auto-populates captured data

**Captured Data:**
```javascript
{
  url: "https://avc.ddev.site/path",
  timestamp: "2026-01-13T15:30:00Z",
  actions: [
    {
      type: "click",
      target: "button#submit.primary",
      timestamp: "2026-01-13T15:30:05Z"
    }
  ],
  console_errors: [
    "TypeError: Cannot read property 'foo' of undefined"
  ]
}
```

**Security:**
- No eval() or innerHTML
- Uses safe DOM methods (textContent, classList)
- Time-limited recording (30s max)
- Opt-in only

### Security Architecture

#### Authentication & Authorization

```yaml
# avc_error_report.routing.yml
avc_error_report.form:
  path: '/report-error'
  defaults:
    _form: '\Drupal\avc_error_report\Form\ErrorReportForm'
    _title: 'Report Error'
  requirements:
    _user_is_logged_in: 'TRUE'
```

**Optional:** Add custom permission for fine-grained control

```yaml
# avc_error_report.permissions.yml
submit error report:
  title: 'Submit error reports'
  description: 'Allows users to submit error reports to GitLab'
```

#### Rate Limiting

**Strategy:** User-based limits with sliding window

**Storage:** KeyValueFactory (persistent, database-backed)

**Configuration:**
- `rate_limit_max`: Default 5
- `rate_limit_window`: Default 3600 (1 hour)

**Bypass:** Admin role can override (optional)

#### Input Sanitization

**Form API:** Automatic sanitization via Drupal Form API

**Additional Validation:**
- URL fields: `#type => 'url'` validation
- Explanation: Minimum 10 characters
- Error message: Maximum 10,000 characters (prevent DOS)
- All text: Xss::filter() before GitLab submission

#### CSRF Protection

**Drupal Form API:** Automatic token generation and validation

**AJAX Endpoints:** Must include form token in headers

#### Token Protection

**Storage:** .secrets.yml (never committed to git)

**Access:** Only server-side via GitLabApiService

**Scope:** Project-level token with `api` permission only

**Fallback:** Admin can override in module config

### Configuration

#### Default Config (config/install/avc_error_report.settings.yml)

```yaml
gitlab_url: 'https://git.nwpcode.org'
project_id: 'avc/avc'
gitlab_token: ''
rate_limit_max: 5
rate_limit_window: 3600
enable_recording: true
```

#### Admin Configuration Form

**Path:** `/admin/config/system/avc-error-report`

**Fields:**
- GitLab URL (default: git.nwpcode.org)
- Project ID (default: avc/avc)
- API Token (optional override)
- Rate limit max (default: 5)
- Rate limit window (default: 3600 seconds)
- Enable/disable recording feature

#### .secrets.yml Integration

```yaml
# .secrets.yml (not committed)
gitlab:
  url: "https://git.nwpcode.org"
  api_token: "glpat-xxxxxxxxxxxxxxxxxxxx"
  project_id: "avc/avc"
```

### User Experience Flow

#### Happy Path

1. User encounters error while browsing
2. Clicks red "Report Error" button in navigation
3. Form opens with previous page auto-filled
4. User types explanation: "I clicked save and got a white screen"
5. User optionally checks "Record next actions"
6. User pastes error message from browser console
7. User clicks "Submit Error Report"
8. Form validates, submits to GitLab
9. Success message: "Thank you! Your report: [Issue #123]"
10. User can click link to view issue on GitLab
11. Developers see formatted issue with all context

#### Recording Flow

1. User checks "Record next actions" box
2. Submits form (or navigates away)
3. Goes to problematic page
4. JavaScript starts recording in background
5. User clicks buttons, fills forms (captured)
6. Error occurs (captured in console)
7. After 30 seconds or navigation, recording stops
8. Data saved to sessionStorage
9. User returns to error form
10. Captured data auto-populates
11. User submits report with rich debugging data

#### Error Paths

**Rate Limit Exceeded:**
- Message: "You've submitted 5 reports in the last hour. Please wait before submitting another."
- No form submission
- User can view but not submit

**GitLab API Failure:**
- Message: "Sorry, we couldn't submit your report. Please try again or email support@..."
- Error logged for admin review
- User prompted to screenshot/copy report

**Validation Errors:**
- Inline field errors (e.g., "Please provide more detail")
- Form not submitted
- User corrects and resubmits

## Implementation Plan

### Phase 1: Core Functionality (MVP)

**Goal:** Basic error reporting to GitLab

**Tasks:**
1. Create module structure and info.yml
2. Implement ErrorReportForm with all fields
3. Add routing and menu link with red button styling
4. Implement GitLabApiService with issue creation
5. Add basic rate limiting (in-memory, simple)
6. Manual testing with test GitLab repo
7. Basic documentation (README.md)

**Deliverables:**
- Working "Report Error" button in navigation
- Functional form that submits to GitLab
- Issues created with proper formatting
- Basic rate limiting (5/hour)

**Success Criteria:**
- [ ] Button visible in navigation bar
- [ ] Form pre-populates previous page
- [ ] Submission creates GitLab issue
- [ ] Issue contains all form data
- [ ] Rate limit prevents spam (simple check)
- [ ] Manual test suite passes

**Estimated Effort:** 2-3 days

### Phase 2: Error Capture Enhancement

**Goal:** JavaScript error recording

**Tasks:**
1. Create error-capture.js library
2. Implement console error capturing
3. Implement click/action recording
4. Add sessionStorage persistence
5. Integrate captured data into form
6. Test cross-page capture scenarios
7. Add enable/disable toggle in form

**Deliverables:**
- Working JavaScript recorder
- Auto-population of captured data
- User control via checkbox

**Success Criteria:**
- [ ] Recording checkbox works
- [ ] Next page actions captured correctly
- [ ] Console errors appear in captured data
- [ ] SessionStorage persists across pages
- [ ] No performance impact observed
- [ ] Works in Chrome, Firefox, Safari

**Estimated Effort:** 1-2 days

### Phase 3: Polish & Production Ready

**Goal:** Production-ready module with tests and docs

**Tasks:**
1. Implement persistent rate limiting (KeyValueFactory)
2. Create ErrorReportSettingsForm for admin
3. Add custom permission (optional)
4. Comprehensive input validation
5. Error handling and logging throughout
6. Write unit tests (services)
7. Write kernel tests (dependency injection)
8. Write functional tests (end-to-end)
9. Complete documentation
10. Code review and refactoring

**Deliverables:**
- Full test coverage (>80%)
- Admin configuration UI
- Production-ready security
- Complete documentation

**Success Criteria:**
- [ ] All security checks pass
- [ ] Rate limiting persists across requests
- [ ] Admin can configure all settings
- [ ] Unit test coverage >80%
- [ ] Functional tests pass
- [ ] Code passes phpcs
- [ ] Documentation complete
- [ ] Peer review approved

**Estimated Effort:** 2-3 days

### Phase 4: Future Enhancements (Optional)

**Goal:** Advanced features for improved UX

**Potential Features:**
- Duplicate detection (check for similar issues before creating)
- Screenshot capture (browser API)
- Browser extension for easier reporting
- Sentry/error tracking service integration
- User notification when issue is resolved
- Admin dashboard with analytics
- Auto-assignment based on error type
- Integration with Slack/Discord for notifications

**Not in Scope for Initial Release**

## Testing Strategy

### Unit Tests

**Target:** Service classes

**Tests:**
- `GitLabApiServiceTest`
  - Test issue title formatting
  - Test description formatting
  - Test API error handling
  - Mock HTTP client responses
- `RateLimitServiceTest`
  - Test limit calculation
  - Test timestamp cleanup
  - Test edge cases (exactly at limit)
- Form validation logic

### Kernel Tests

**Target:** Drupal integration

**Tests:**
- Service registration and dependency injection
- Configuration management (CRUD)
- Key-value storage operations
- Permission checks

### Functional Tests

**Target:** End-to-end user flows

**Tests:**
- `ErrorReportFormTest`
  - Anonymous users cannot access
  - Authenticated users see form
  - Form submission creates GitLab issue
  - Rate limiting prevents spam
  - Validation errors shown correctly
  - Success message with issue link
- Navigation button visibility
- Recording feature cross-page flow

### Manual Testing Checklist

**User Interface:**
- [ ] "Report Error" button appears in navigation
- [ ] Button is red and visually prominent
- [ ] Button is keyboard accessible (Tab + Enter)
- [ ] Mobile responsive (button and form)

**Form Functionality:**
- [ ] Previous page auto-populates correctly
- [ ] All fields accept valid input
- [ ] Required fields enforce validation
- [ ] URL field rejects invalid URLs
- [ ] Explanation field requires 10+ characters
- [ ] Error message field accepts long text (stack traces)

**GitLab Integration:**
- [ ] Issue created successfully
- [ ] Issue title format correct
- [ ] Issue description includes all data
- [ ] Issue has correct labels
- [ ] Issue URL returned to user
- [ ] User can access issue (permissions)

**Rate Limiting:**
- [ ] First 5 submissions succeed
- [ ] 6th submission blocked with message
- [ ] After 1 hour, can submit again
- [ ] Rate limit persists across sessions

**Error Recording:**
- [ ] Checkbox enables recording
- [ ] Next page actions captured
- [ ] Console errors captured
- [ ] Data persists via sessionStorage
- [ ] Recording stops after 30 seconds
- [ ] Captured data appears in form
- [ ] No performance impact

**Security:**
- [ ] CSRF tokens prevent forgery
- [ ] Input sanitization prevents XSS
- [ ] API token never exposed in HTML/JS
- [ ] Rate limiting prevents abuse
- [ ] Validation prevents oversized inputs

**Accessibility:**
- [ ] Screen reader announces all fields
- [ ] Keyboard navigation works throughout
- [ ] Focus indicators visible
- [ ] Error messages programmatically associated
- [ ] ARIA labels present and correct

**Browser Compatibility:**
- [ ] Chrome/Chromium
- [ ] Firefox
- [ ] Safari
- [ ] Edge
- [ ] Mobile browsers (iOS Safari, Chrome Android)

## Security Considerations

### Threat Model

**Threat:** Spam/Abuse
- **Attack:** User submits hundreds of fake reports
- **Mitigation:** Rate limiting (5/hour), user accountability
- **Impact:** Medium (wastes developer time, clutters issues)

**Threat:** XSS via User Input
- **Attack:** User includes malicious script in explanation
- **Mitigation:** Drupal Form API sanitization, Xss::filter()
- **Impact:** High (could compromise other users/admins)

**Threat:** API Token Compromise
- **Attack:** Attacker gains access to .secrets.yml or config
- **Mitigation:** File permissions, .gitignore, token rotation
- **Impact:** High (could create/modify any issues)

**Threat:** Information Disclosure
- **Attack:** User includes sensitive data in report
- **Mitigation:** User education, admin review, optional confidential flag
- **Impact:** Medium (PII exposure)

**Threat:** CSRF Attack
- **Attack:** Malicious site tricks user into submitting report
- **Mitigation:** Drupal Form API CSRF tokens
- **Impact:** Low (requires authenticated user)

**Threat:** DOS via Large Inputs
- **Attack:** User submits massive error messages
- **Mitigation:** Field length limits, rate limiting
- **Impact:** Low (limited by rate limits)

### Security Best Practices Applied

1. **Principle of Least Privilege**
   - API token has only `api` scope
   - Only authenticated users can submit
   - Optional custom permission for further restriction

2. **Defense in Depth**
   - Client-side validation (UX)
   - Server-side validation (security)
   - Rate limiting (abuse prevention)
   - Logging (audit trail)

3. **Secure Defaults**
   - Rate limiting enabled by default
   - Recording opt-in only
   - Conservative field length limits

4. **Input Validation**
   - Whitelist validation (URL fields)
   - Length limits (DOS prevention)
   - Type checking (form API)
   - Sanitization (XSS prevention)

5. **Error Handling**
   - Never expose internal errors to users
   - Log all failures for admin review
   - Graceful degradation (show generic message)

6. **Secrets Management**
   - API token in .secrets.yml (not committed)
   - Never exposed to client
   - Rotatable without code changes

## Success Metrics

### Adoption Metrics

**Target:** Measure how many users use the feature

- **Metric 1:** % of active users who submit ≥1 report
  - **Target:** 25% within 3 months
  - **Measurement:** Drupal logs, GitLab issue counts

- **Metric 2:** Time to first report for new users
  - **Target:** <1 week average
  - **Measurement:** User registration date vs first report

### Quality Metrics

**Target:** Measure usefulness of reports

- **Metric 1:** % of reports marked "actionable"
  - **Target:** 80%+
  - **Measurement:** GitLab labels (valid/invalid/duplicate)

- **Metric 2:** Average developer response time
  - **Target:** <24 hours for critical, <1 week for normal
  - **Measurement:** Issue creation to first comment

- **Metric 3:** % of reports leading to bug fixes
  - **Target:** 50%+
  - **Measurement:** Issues with fix commits linked

### Performance Metrics

**Target:** Ensure good performance

- **Metric 1:** Form load time (p95)
  - **Target:** <200ms
  - **Measurement:** Browser timing API, logs

- **Metric 2:** GitLab API response time (p95)
  - **Target:** <3s
  - **Measurement:** Service timing logs

- **Metric 3:** JavaScript recording overhead
  - **Target:** <5% CPU, <1MB memory
  - **Measurement:** Browser profiling

### User Satisfaction

**Target:** Users find it helpful

- **Metric 1:** User feedback rating
  - **Target:** 4.0+ / 5.0
  - **Measurement:** Optional survey after 3rd report

- **Metric 2:** Feature usage retention
  - **Target:** 60%+ of users who report once report again
  - **Measurement:** User IDs in reports over time

## Dependencies

### External Dependencies

- **GitLab API v4:** For issue creation
  - Version: v4 (stable)
  - Documentation: https://docs.gitlab.com/ee/api/issues.html
  - Authentication: Personal/Project access token

- **Drupal Core:** 9.5+ or 10.x
  - Form API
  - HTTP client (Guzzle)
  - KeyValue storage
  - Config API

### Internal Dependencies

- **No AVC module dependencies:** Standalone module
- **.secrets.yml:** For GitLab token (optional, can use admin config)

### Development Dependencies

- **PHPUnit:** For unit/kernel/functional tests
- **Drupal Test Traits:** For test helpers
- **PHP CodeSniffer:** For coding standards

## Risks & Mitigation

### Technical Risks

**Risk:** GitLab API changes break integration
- **Probability:** Low
- **Impact:** High
- **Mitigation:** Version lock API endpoints, monitor GitLab changelog, add integration tests
- **Contingency:** Fallback to email-based reporting

**Risk:** JavaScript recorder causes performance issues
- **Probability:** Medium
- **Impact:** Medium
- **Mitigation:** Time limits (30s), opt-in only, performance testing
- **Contingency:** Make recording admin-disabled, optimize recording logic

**Risk:** Rate limiting is bypassed by sophisticated attacker
- **Probability:** Low
- **Impact:** Medium
- **Mitigation:** Additional IP-based limits, honeypot fields, admin monitoring
- **Contingency:** Temporarily disable module, tighten limits

### Operational Risks

**Risk:** API token compromise
- **Probability:** Low
- **Impact:** High
- **Mitigation:** File permissions, .gitignore, regular rotation, audit logging
- **Contingency:** Immediately revoke token, create new one, review all issues

**Risk:** Spam/abuse of reporting system
- **Probability:** Medium
- **Impact:** Low
- **Mitigation:** Rate limiting, user accountability, admin review dashboard
- **Contingency:** Ban abusive users, tighten rate limits, add CAPTCHA

**Risk:** Users include sensitive data in reports
- **Probability:** Medium
- **Impact:** Medium
- **Mitigation:** User education, admin review, optional confidential flag
- **Contingency:** Delete sensitive issues, educate user, update UI warnings

### Adoption Risks

**Risk:** Users don't discover or use feature
- **Probability:** Medium
- **Impact:** Medium
- **Mitigation:** Prominent button, user education, in-app prompts
- **Contingency:** Add onboarding tour, email announcement, documentation

**Risk:** Reports lack useful information
- **Probability:** Medium
- **Impact:** Medium
- **Mitigation:** Required fields, helpful placeholders, recording feature
- **Contingency:** Add more guidance, templates, examples

## Maintenance Plan

### Ongoing Maintenance

**Tasks:**
- Monitor GitLab API for changes (monthly review)
- Review error logs for failures (weekly)
- Update dependencies (quarterly)
- Rotate API tokens (annually or on compromise)
- Review and triage reported issues (daily)

**Effort:** ~2 hours/week average

### Future Enhancements

**Potential Improvements:**
- Duplicate detection algorithm
- Screenshot capture integration
- Advanced analytics dashboard
- Machine learning for auto-categorization
- Integration with other error tracking services

**Prioritization:** Based on user feedback and adoption metrics

## Documentation Deliverables

### Developer Documentation

1. **README.md** (Module root)
   - Overview and purpose
   - Installation instructions
   - Configuration guide
   - Development setup
   - Testing instructions
   - Contributing guidelines

2. **API.md** (Module root)
   - Service documentation
   - Public methods and parameters
   - Example usage
   - Extension points

3. **Inline Code Comments**
   - PHPDoc blocks for all classes and methods
   - Complex logic explanations
   - Security notes where relevant

### User Documentation

1. **USER_GUIDE.md** (Module root or AVC docs)
   - How to report an error
   - What information to include
   - How to use recording feature
   - What happens after submission
   - FAQ

2. **ADMIN_GUIDE.md** (Module root or AVC docs)
   - Configuration instructions
   - GitLab setup and token creation
   - Rate limiting configuration
   - Monitoring and troubleshooting
   - Security best practices

### Integration Documentation

1. **docs/decisions/ADR-XXX-error-reporting.md**
   - Architecture Decision Record
   - Why this approach was chosen
   - Alternatives considered
   - Trade-offs and implications

## Alternatives Considered

### Alternative 1: Third-Party Error Tracking (e.g., Sentry)

**Pros:**
- More features (automatic error capture, source maps, releases)
- Less development effort
- Professional support

**Cons:**
- External dependency and cost
- Less control over data
- Requires ongoing subscription
- Not user-initiated reports

**Decision:** Rejected for initial implementation, but could integrate later

### Alternative 2: Email-Based Reporting

**Pros:**
- Simpler implementation
- No GitLab API dependency
- Users familiar with email

**Cons:**
- Manual triage required
- No automatic formatting
- Harder to track and organize
- No direct link to codebase

**Decision:** Rejected as primary approach, but useful as fallback

### Alternative 3: Built-in Drupal Logging

**Pros:**
- No external dependencies
- Already integrated with Drupal
- Fast and reliable

**Cons:**
- Not visible to external developers
- No user-friendly interface
- Requires server access to view
- Not collaborative

**Decision:** Complement with this module, not replace

### Alternative 4: Forum/Support Tickets

**Pros:**
- User-friendly
- Encourages community support
- Searchable by other users

**Cons:**
- Not directly linked to code
- Requires manual developer follow-up
- Less structured data
- Slower for developers

**Decision:** Use for general support, not bug reporting

## Conclusion

The AVC Error Reporting Module will significantly improve the bug reporting workflow by:

1. **Reducing Friction:** One-click access to reporting form
2. **Improving Quality:** Auto-captured context and optional recording
3. **Accelerating Development:** Direct GitLab integration with formatted issues
4. **Preventing Abuse:** Rate limiting and security measures
5. **Empowering Users:** Transparency via issue links and follow-up

The phased implementation allows for iterative development:
- **Phase 1 (MVP):** Immediate value with basic reporting
- **Phase 2 (Enhanced):** Advanced debugging with error capture
- **Phase 3 (Production):** Security, testing, and polish

**Total Estimated Effort:** 5-8 days for production-ready module

**Next Steps:**
1. ✅ Create proposal document (this document)
2. ⏭ Review and approve proposal
3. ⏭ Set up GitLab project board with milestones
4. ⏭ Configure test environment and test GitLab repo
5. ⏭ Begin Phase 1 implementation

## Appendix: Configuration Examples

### GitLab API Token Setup

```bash
# On GitLab (git.nwpcode.org):
# 1. Navigate to AVC project
# 2. Settings > Access Tokens
# 3. Create token with:
#    - Name: "AVC Error Reporting Module"
#    - Role: Developer
#    - Scopes: api
#    - Expiration: 1 year from now

# In .secrets.yml:
gitlab:
  url: "https://git.nwpcode.org"
  api_token: "glpat-xxxxxxxxxxxxxxxxxxxx"
  project_id: "avc/avc"
```

### Module Configuration

```bash
# Enable module
drush en avc_error_report -y

# Configure via drush
drush config:set avc_error_report.settings gitlab_url 'https://git.nwpcode.org' -y
drush config:set avc_error_report.settings project_id 'avc/avc' -y
drush config:set avc_error_report.settings rate_limit_max 5 -y

# Or via admin UI: /admin/config/system/avc-error-report
```

### Testing Configuration

```bash
# Set up test GitLab repo for development
drush config:set avc_error_report.settings project_id 'avc/avc-test' -y

# Disable rate limiting for testing
drush config:set avc_error_report.settings rate_limit_max 9999 -y

# Run tests
drush test avc_error_report
```

---

**Document Version:** 1.0
**Last Updated:** 2026-01-13
**Status:** PROPOSED - Awaiting approval
