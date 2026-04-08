# Python Alternatives for AVC (AV Commons)

An investigation into recreating AVC functionality using Python instead of Drupal/Open Social.

## Current AVC Functionality (Drupal/Open Social)

AVC is a **collaborative workflow and community platform** built on Drupal 10 and Open Social with these core features:

| Module | Function |
|--------|----------|
| **avc_core** | Foundation services for all AVC modules |
| **avc_member** | User profiles, dashboards, worklists |
| **avc_group** | Group workflows, task dashboards |
| **avc_guild** | Specialized groups with mentorship, scoring, endorsements |
| **avc_asset** | Project/document management |
| **avc_notification** | Custom notifications, digests |
| **avc_content** | Pages, menus, initial content |
| **workflow_assignment** | Task assignment to users/groups/destinations |

### Key Characteristics

- Built on **Open Social** (social networking foundation)
- Focus on group collaboration and task management
- Member-based organization system
- Structured workflow and asset management
- Guild/community organization structure with mentorship

---

## Python Framework Options

### 1. Wagtail CMS (Recommended for CMS Core)

- Modern, well-maintained Python CMS
- Excellent content editing experience with StreamField blocks
- Highly extensible with Django
- Strong community, active development
- Used by Google, NASA, Mozilla
- Website: [wagtail.org](https://wagtail.org/)

### 2. Django CMS

- More traditional CMS approach
- Extensive plugin ecosystem
- Drag-and-drop editing
- Multi-language built-in
- Website: [django-cms.org](https://www.django-cms.org/)

### 3. Raw Django + Components

- Maximum flexibility
- Combine purpose-built packages
- More development effort, full control

---

## Component Mapping: AVC Features to Python

| AVC Feature | Python Solution | Package/Framework |
|-------------|-----------------|-------------------|
| **CMS/Content** | Wagtail or Django CMS | [wagtail](https://wagtail.org/) |
| **Social Networking** | Pinax or custom | [Pinax](https://pinaxproject.com/) |
| **Workflow/State Machine** | django-river or Viewflow | [django-river](https://django-river.readthedocs.io/), [Viewflow](https://viewflow.io/) |
| **Task Management** | django-todo | [django-todo](https://pypi.org/project/django-todo/) |
| **Groups/Membership** | django-organizations + custom | django-organizations |
| **Notifications** | django-notifications-hq | django-notifications-hq |
| **User Profiles** | Django allauth + custom | django-allauth |
| **Activity Streams** | django-activity-stream | django-activity-stream |
| **Comments** | django-comments-xtd | django-comments-xtd |
| **Search** | Wagtail Search or django-haystack | elasticsearch/postgres |

---

## Recommended Approaches

### Option A: Wagtail + Django Extensions (Recommended)

```
Wagtail CMS
├── Content Management (pages, assets, media)
├── User Management (django-allauth)
├── Groups (django-organizations or custom)
├── Workflows (django-river for state machines)
├── Tasks (django-todo or custom)
├── Notifications (django-notifications-hq)
├── Activity Feed (django-activity-stream)
└── Search (Wagtail Search + Elasticsearch)
```

**Pros:**
- Wagtail provides excellent CMS foundation
- All components are Python/Django native
- Full control over customization
- Modern tech stack (Python 3.11+, Django 5.x)
- Easier to maintain than Drupal

**Cons:**
- No out-of-box "Open Social" equivalent
- Need to build social/guild features custom
- Initial development effort higher

### Option B: MemberMatters + Wagtail Hybrid

Use [MemberMatters](https://github.com/membermatters/MemberMatters) for membership/access management combined with Wagtail for content.

**Pros:**
- Ready-made membership portal
- Payment integration included

**Cons:**
- Focused on makerspaces, may need heavy customization

### Option C: Full Custom Django

Build everything from scratch using Django + packages:

```python
# requirements.txt
django>=5.0
wagtail>=6.0  # or skip for pure Django
django-allauth  # Authentication
django-organizations  # Groups
django-river  # Workflow state machine
django-todo  # Task management
django-notifications-hq  # Notifications
django-activity-stream  # Activity feeds
django-comments-xtd  # Comments
channels  # WebSockets for real-time
celery  # Background tasks
```

---

## Architecture Comparison

| Aspect | Current (Drupal/AVC) | Python/Wagtail |
|--------|---------------------|----------------|
| **Language** | PHP 8.2 | Python 3.11+ |
| **Framework** | Drupal 10 + Open Social | Django 5.x + Wagtail |
| **Database** | MariaDB/MySQL | PostgreSQL (recommended) |
| **Workflow** | Custom module | django-river |
| **Caching** | Redis/Drupal Cache | Redis/Django Cache |
| **Search** | Solr | Elasticsearch/PostgreSQL FTS |
| **Theming** | Twig templates | Django/Jinja2 templates |
| **API** | Drupal JSON:API | Django REST Framework |

---

## Development Effort Estimate

| Approach | Complexity | What You Get |
|----------|------------|--------------|
| **Wagtail + Extensions** | Medium | Modern CMS + custom workflow |
| **Pinax Starter** | Medium-Low | Social foundation, needs workflow |
| **Full Custom Django** | High | Complete control, most work |

---

## Recommendation

For recreating AVC functionality in Python, the recommended approach is **Wagtail CMS + Django extensions**:

1. **Wagtail** for content management, pages, media, and search
2. **django-river** for workflow state machines (replaces workflow_assignment)
3. **django-organizations** for groups/guilds structure
4. **django-notifications-hq** for notifications
5. **django-activity-stream** for activity feeds
6. **Custom models** for member dashboards and worklists

This provides a maintainable, modern Python stack while replicating AVC's key features.

---

## Key Python Packages Reference

### CMS & Content

| Package | Purpose | Link |
|---------|---------|------|
| wagtail | Full CMS with StreamField | [wagtail.org](https://wagtail.org/) |
| django-cms | Traditional CMS with plugins | [django-cms.org](https://www.django-cms.org/) |

### Workflow & Tasks

| Package | Purpose | Link |
|---------|---------|------|
| django-river | On-the-fly workflow management | [django-river.readthedocs.io](https://django-river.readthedocs.io/) |
| viewflow | Business process automation | [viewflow.io](https://viewflow.io/) |
| django-todo | Multi-user task management | [pypi.org/project/django-todo](https://pypi.org/project/django-todo/) |

### Social & Community

| Package | Purpose | Link |
|---------|---------|------|
| pinax | Social network starter projects | [pinaxproject.com](https://pinaxproject.com/) |
| django-activity-stream | Activity feeds | [github.com/justquick/django-activity-stream](https://github.com/justquick/django-activity-stream) |
| django-notifications-hq | User notifications | [github.com/django-notifications/django-notifications](https://github.com/django-notifications/django-notifications) |

### Users & Groups

| Package | Purpose | Link |
|---------|---------|------|
| django-allauth | Authentication & social auth | [django-allauth.readthedocs.io](https://django-allauth.readthedocs.io/) |
| django-organizations | Multi-user organizations | [github.com/bennylope/django-organizations](https://github.com/bennylope/django-organizations) |

### Membership Platforms

| Package | Purpose | Link |
|---------|---------|------|
| MemberMatters | Membership & access portal | [github.com/membermatters/MemberMatters](https://github.com/membermatters/MemberMatters) |

---

## Sources

- [Wagtail CMS](https://wagtail.org/)
- [Django CMS vs Wagtail Comparison](https://blog.logrocket.com/comparing-wagtail-vs-django-cms/)
- [Viewflow Workflow Engine](https://viewflow.io/)
- [django-river Documentation](https://django-river.readthedocs.io/)
- [django-todo on PyPI](https://pypi.org/project/django-todo/)
- [Pinax Project](https://pinaxproject.com/)
- [MemberMatters](https://github.com/membermatters/MemberMatters)
- [Top Python CMS Options](https://www.esparkinfo.com/software-development/technologies/python/best-cms)
- [Django Social Packages](https://djangopackages.org/grids/g/social/)
- [Django Workflow Packages](https://djangopackages.org/grids/g/workflow/)
