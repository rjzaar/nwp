# AVC Folder Module Implementation Plan

**Module Name:** `avc_folder`
**Purpose:** Provide Google Drive-like folder management for AV Commons
**Approach:** Integration module wrapping contrib modules with Open Social group integration

---

## Overview

This plan implements the Media + Taxonomy + File Field Paths approach recommended in `folder_proposal.md`. The `avc_folder` module acts as a lightweight integration layer that:

- Configures contrib modules for AVC's needs
- Integrates folder management with Open Social groups
- Provides appropriate permissions and access control

---

## Implementation Phases

### Phase 1: Module Scaffolding

**1.1 Create module structure**

```
web/modules/custom/avc_folder/
├── avc_folder.info.yml
├── avc_folder.install
├── avc_folder.module
├── avc_folder.permissions.yml
├── avc_folder.libraries.yml
├── config/
│   ├── install/
│   │   ├── taxonomy.vocabulary.media_folders.yml
│   │   ├── field.storage.media.field_media_folder.yml
│   │   ├── field.field.media.document.field_media_folder.yml
│   │   └── media_directories.settings.yml
│   └── optional/
│       └── views.view.group_files.yml
├── src/
│   └── EventSubscriber/
│       └── GroupFolderSubscriber.php
└── libraries/
    └── jstree/ (or reference external)
```

**1.2 Define module info and dependencies**

```yaml
# avc_folder.info.yml
name: 'AVC Folder'
type: module
description: 'Folder-based file management for AV Commons groups'
package: AVC
core_version_requirement: ^10
dependencies:
  - drupal:media
  - drupal:media_library
  - drupal:taxonomy
  - media_directories:media_directories
  - media_directories:media_directories_ui
  - filefield_paths:filefield_paths
  - social_group:social_group
```

---

### Phase 2: Taxonomy & Media Configuration

**2.1 Create "Media Folders" vocabulary**

Config file: `config/install/taxonomy.vocabulary.media_folders.yml`

```yaml
langcode: en
status: true
dependencies: {}
name: 'Media Folders'
vid: media_folders
description: 'Hierarchical folder structure for organising media files'
weight: 0
```

**2.2 Add folder reference field to Media types**

- Field storage: `field_media_folder` (entity_reference to taxonomy term)
- Attach to Document, Image, and other relevant media types
- Configure widget for Media Directories integration

**2.3 Configure Media Directories**

- Set vocabulary to `media_folders`
- Enable jsTree browser interface
- Configure CKEditor integration for folder-aware media embedding

---

### Phase 3: File Field Paths Configuration

**3.1 Configure token-based file paths**

For each media type's file field:

```
File path: media-library/[media:field_media_folder:entity:parents:join-path]/[media:field_media_folder:entity:name]
Options:
  - Transliterate: Yes
  - Lowercase: Yes
  - Remove extra slashes: Yes
Active updating: Yes
```

**3.2 Result**

User's logical organisation mirrors physical storage:

```
Taxonomy terms:              Physical files:
├── Group A/                 files/media-library/
│   ├── Documents/           ├── group-a/documents/
│   └── Images/              └── group-a/images/
└── Group B/
    └── Shared/              └── group-b/shared/
```

---

### Phase 4: Open Social Group Integration

**4.1 Auto-create group root folder**

When an Open Social group is created, automatically create a corresponding root taxonomy term:

```php
// src/EventSubscriber/GroupFolderSubscriber.php

namespace Drupal\avc_folder\EventSubscriber;

use Symfony\Component\EventDispatcher\EventSubscriberInterface;
use Drupal\social_group\Event\GroupCreateEvent;

class GroupFolderSubscriber implements EventSubscriberInterface {

  public static function getSubscribedEvents() {
    return [
      'social_group.create' => 'onGroupCreate',
    ];
  }

  public function onGroupCreate(GroupCreateEvent $event) {
    $group = $event->getGroup();

    // Create root folder term for this group
    $term = Term::create([
      'vid' => 'media_folders',
      'name' => $group->label(),
      'field_group_reference' => $group->id(),
    ]);
    $term->save();
  }
}
```

**4.2 Add group reference to taxonomy terms**

- Add `field_group_reference` (entity_reference) to media_folders vocabulary
- Links folders to their owning group

**4.3 Implement access control**

```php
// avc_folder.module

use Drupal\Core\Access\AccessResult;

/**
 * Implements hook_ENTITY_TYPE_access() for taxonomy_term.
 */
function avc_folder_taxonomy_term_access($term, $operation, $account) {
  if ($term->bundle() !== 'media_folders') {
    return AccessResult::neutral();
  }

  // Check if user is member of the folder's group
  $group_id = $term->get('field_group_reference')->target_id;
  if ($group_id) {
    $group = \Drupal::entityTypeManager()
      ->getStorage('group')
      ->load($group_id);

    if ($group && $group->getMember($account)) {
      return AccessResult::allowed()
        ->addCacheableDependency($term)
        ->addCacheableDependency($group);
    }
  }

  return AccessResult::neutral();
}
```

---

### Phase 5: Permissions

**5.1 Define custom permissions**

```yaml
# avc_folder.permissions.yml

create avc folder:
  title: 'Create folders'
  description: 'Create new folders within groups the user belongs to'

delete own avc folder:
  title: 'Delete own folders'
  description: 'Delete folders created by the user'

delete any avc folder:
  title: 'Delete any folder'
  description: 'Delete any folder (admin permission)'
  restrict access: true

manage group folders:
  title: 'Manage group folders'
  description: 'Full folder management within owned/administered groups'
```

**5.2 Map to Open Social roles**

| Permission | Verified | Content Manager | Site Manager |
|------------|:--------:|:---------------:|:------------:|
| create avc folder | Yes | Yes | Yes |
| delete own avc folder | Yes | Yes | Yes |
| delete any avc folder | No | No | Yes |
| manage group folders | No | Yes | Yes |

---

### Phase 6: Views Integration

**6.1 Group files view**

Create a View displaying files within a group's folder structure:

- **Path:** `/group/{group}/files`
- **Display:** Table with columns: Name, Type, Size, Uploaded, Actions
- **Contextual filter:** Group ID from URL
- **Exposed filter:** Folder (taxonomy term)
- **Sort:** Folder hierarchy, then filename

**6.2 User's files dashboard**

- **Path:** `/user/{user}/files`
- **Shows:** All files uploaded by the user across groups
- **Grouped by:** Group membership

---

### Phase 7: UI Enhancements

**7.1 jsTree library installation**

Option A: Composer with asset-packagist
```json
{
  "repositories": [
    {
      "type": "composer",
      "url": "https://asset-packagist.org"
    }
  ],
  "require": {
    "npm-asset/jstree": "^3.3"
  }
}
```

Option B: Manual installation
```bash
cd web/libraries
wget https://github.com/vakata/jstree/archive/refs/tags/3.3.16.zip
unzip 3.3.16.zip && mv jstree-3.3.16 jstree
```

**7.2 Custom styling**

Match Open Social theme styling for consistency:
- Folder icons
- Upload button placement
- Breadcrumb navigation

---

## Installation Steps (NWP)

```bash
# 1. Install contrib dependencies
ddev composer require drupal/media_directories drupal/filefield_paths

# 2. Install jsTree library
cd web/libraries
wget https://github.com/vakata/jstree/archive/refs/tags/3.3.16.zip
unzip 3.3.16.zip && mv jstree-3.3.16 jstree && rm 3.3.16.zip

# 3. Enable the module
ddev drush en avc_folder -y

# 4. Import configuration
ddev drush cim --partial --source=modules/custom/avc_folder/config/install -y

# 5. Clear caches
ddev drush cr
```

---

## Testing Checklist

- [ ] Module installs without errors
- [ ] Media Folders vocabulary created
- [ ] jsTree folder browser displays correctly
- [ ] Users can create folders within their groups
- [ ] Users cannot access folders in groups they don't belong to
- [ ] Files upload to correct physical path based on folder
- [ ] Moving files between folders updates physical location
- [ ] Group files view displays correctly
- [ ] CKEditor media embed shows folder browser

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| `filefield_paths` no stable D10 release | Medium | Test thoroughly; fallback to manual paths |
| Open Social event API changes | Low | Use hooks as fallback for group creation |
| jsTree library conflicts | Low | Isolate in module namespace |
| Performance with large folder trees | Medium | Implement lazy loading, pagination |

---

## Future Enhancements

1. **Drag-and-drop reordering** of folders in tree
2. **Folder sharing** outside of groups (user-to-user)
3. **Storage quotas** per group
4. **Version history** for files using Media revisions
5. **Bulk operations** (move/delete multiple files)
6. **S3 storage** integration via Flysystem

---

## References

- [folder_proposal.md](folder_proposal.md) - Original requirements analysis
- [Media Directories](https://www.drupal.org/project/media_directories)
- [File Field Paths](https://www.drupal.org/project/filefield_paths)
- [Open Social Group API](https://www.drupal.org/docs/contributed-modules/open-social)

---

*Document created: January 2026*
*For: AV Commons (AVC) project*
