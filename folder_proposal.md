# Document Management Solutions for AV Commons (AVC)

**Evaluation of Folder-Based File Management Options**

---

**Prepared by:** Rob Zaar  
**Date:** January 2026  
**Version:** 1.0

---

## Executive Summary

AV Commons requires document management functionality similar to Google Drive, enabling members to organise, share, and collaborate on files within a folder hierarchy. This proposal evaluates three Drupal-based solutions for implementation within the Open Social platform, with deployment and management via NWP (Narrow Way Project).

The three options evaluated are:

1. **FolderShare** — Google Drive-like user-managed file sharing
2. **Filebrowser** — FTP-style directory exposure for admin-controlled folders
3. **Media + Taxonomy + File Field Paths** — Drupal-native approach using core Media with taxonomy organisation

---

## AVC Requirements

Based on the AVC specifications and Apostoli Viae's collaborative workflow needs, the document management system should support:

| Requirement | Description |
|-------------|-------------|
| **Folder Hierarchy** | Nested folder structure for organising documents by project, group, or topic |
| **Group Integration** | Files should be accessible at group level with appropriate permissions |
| **User Self-Service** | Members should be able to create folders and upload files without admin intervention |
| **Sharing Controls** | Private by default with ability to share with specific users or groups |
| **Drag-and-Drop** | Modern upload interface with drag-and-drop support |
| **Views Integration** | Ability to display files in custom Views for dashboards and listings |
| **Open Social Compatible** | Must work within Open Social 12.x architecture and theming |

---

## Option 1: FolderShare

FolderShare is a purpose-built document management module that provides the closest experience to Google Drive. Users create and manage their own folder trees with files stored in the database and filesystem.

### How It Works

FolderShare creates a custom entity type (not nodes) for managing files and folders. The folder hierarchy exists in the database while physical files use machine-generated names for security. Users see a familiar folder structure while the backend maintains organised, secure storage.

```
User sees:               Filesystem reality:
├── Projects/            ├── ab/
│   ├── Client A/        │   └── 3f2a7b...
│   └── Client B/        ├── cd/
└── Personal/            │   └── 9e4c1a...
```

### Key Features

- **Drag-and-drop uploads** directly into folders
- **Full file operations:** move, copy, rename, duplicate, delete, download
- **Sharing model:** Private by default, share with specific users (view/edit), or make public
- **REST API** via companion module for CLI/programmatic access
- **Usage reports** for administrators
- **Search** through file repository

### Pros

- Most Google Drive-like experience for end users
- Users can create their own folder structures
- Built-in user-level sharing permissions
- Secure file storage with machine-generated paths
- Low complexity setup

### Cons

- **Alpha status only** (3.1.0-alpha5 for Drupal 10)
- **No PostgreSQL support** — MySQL/SQLite only
- **Subfolder deployments don't work** — must be on top-level domain
- Custom entity type requires additional work for Views integration
- Not natively group-aware — would need custom integration for Open Social groups

### NWP Installation

```bash
composer require 'drupal/foldershare:^3.1@alpha'
```

### Links

- Project: https://www.drupal.org/project/foldershare
- Demo: https://seedmelab.org/try-now

---

## Option 2: Filebrowser

Filebrowser exposes existing server directories to users through a node-based interface, similar to an FTP client. Each directory listing is a Drupal node that maps to a physical filesystem location.

### How It Works

Administrators create 'Directory Listing' nodes that point to actual filesystem directories. When users view these nodes, they see the contents of that directory with upload/download capabilities based on their permissions. The physical folder structure directly mirrors what users see.

```
Node "Company Documents" → points to → public://company-docs/
Node "Team Files"        → points to → private://team-files/
Node "Archive"           → points to → s3://archive-bucket/
```

### Key Features

- **Directory-to-node mapping:** Each folder listing is a standard Drupal node
- **Permission control:** Upload/download/view permissions per role, per node
- **Private file downloads:** Supports Drupal private file system
- **Remote storage support:** S3, Dropbox via Flysystem integration
- **File blacklists:** Exclude specific files from listings
- **Stable release** with active maintenance

### Pros

- Stable, mature module with security coverage
- Node-based means standard Drupal/Open Social permissions work
- Can create a directory listing node per Open Social group
- Physical folder structure matches user view
- Supports remote storage (S3, etc.)

### Cons

- **Admin-controlled structure:** Users cannot create their own folders
- **Folder renaming not allowed** in D10 version
- Less intuitive than Google Drive experience
- Best suited for admin-defined shared folders rather than user-managed files

### NWP Installation

```bash
composer require drupal/filebrowser
```

### Configuration

```php
// In settings.php for Flysystem/S3 support:
$schemes['s3'] = [
  'driver' => 's3',
  'config' => [
    'key' => 'your_key',
    'secret' => 'your_secret',
    'region' => 'eu-west-1',
    'bucket' => 'your_bucket',
  ],
];
```

### Links

- Project: https://www.drupal.org/project/filebrowser
- Documentation: https://www.drupal.org/docs/contributed-modules/filebrowser

---

## Option 3: Media + Taxonomy + File Field Paths

This approach combines Drupal core's Media system with contributed modules to create a taxonomy-based virtual folder structure. It's the most 'Drupal-native' solution and integrates deeply with existing content workflows.

### How It Works

A taxonomy vocabulary defines the folder hierarchy, with each term representing a folder. The Media Directories module provides a jsTree-based interface for browsing and organising media. File Field Paths can optionally mirror the logical structure to the physical filesystem.

### Module Stack

| Module | Purpose |
|--------|---------|
| `media` (core) | Entity type for files with metadata, revisions, reuse |
| `media_library` (core) | Browse/select UI for media entities |
| `media_directories` | jsTree folder browser, taxonomy-based organisation |
| `filefield_paths` | Token-based physical file organisation (optional) |

### Key Features

- **jsTree interface** with drag-and-drop
- **CKEditor integration** — folder-aware media embed button
- **Full Views integration** — media entities work with all Views features
- **Permission by Term** integration for folder-level access (experimental)
- **Physical folder mirroring** with File Field Paths
- **Entity Browser widget** for content type fields

### Setup Steps

1. Create taxonomy vocabulary "Media Folders"
2. Add hierarchical terms: Products > Images, Documents > PDFs, etc.
3. Configure at `/admin/config/media/media_directories`
4. Enable submodules: `media_directories_ui`, `media_directories_editor`
5. Install jsTree library to `/libraries/jstree/dist/jstree.min.js`

### File Field Paths Configuration (Physical Mirroring)

On your media type's file field:

```
File path: media-library/[media:directory:entity:parents:join-path]/[media:directory:entity:name]
File path options: ✓ Transliterate, ✓ Lowercase, ✓ Remove extra slashes
Active Updating: ✓ (moves files when folder changes)
```

This creates:

```
User organises as:           Physical storage:
├── Products/                sites/default/files/media-library/
│   └── Widgets/             ├── products/widgets/
│       └── logo.png         │   └── logo.png
└── Marketing/               └── marketing/
    └── brochure.pdf             └── brochure.pdf
```

### Pros

- Most Drupal-native approach — works with existing content workflows
- Media entities integrate with Views, Search, and Open Social
- Users can create folders (taxonomy terms with proper permissions)
- Can combine with `permissions_by_entity` for folder-level access
- Stable core modules with contrib enhancements

### Cons

- **Higher complexity:** Multiple modules to configure
- **filefield_paths** still in dev for D10 (works but no stable release)
- Requires jsTree library installation
- More setup time than other options

### NWP Installation

```bash
composer require drupal/media_directories drupal/filefield_paths

# Download jsTree library
cd web/libraries
wget https://github.com/vakata/jstree/archive/refs/tags/3.3.16.zip
unzip 3.3.16.zip
mv jstree-3.3.16 jstree
```

### Links

- Media Directories: https://www.drupal.org/project/media_directories
- File Field Paths: https://www.drupal.org/project/filefield_paths

---

## Comparison Matrix

| Feature | FolderShare | Filebrowser | Media+Taxonomy |
|---------|:-----------:|:-----------:|:--------------:|
| User creates folders | ✅ Yes | ❌ Admin only | ✅ Yes |
| Drag-drop upload | ✅ Yes | ✅ Yes | ✅ Yes |
| User-level sharing | ✅ Built-in | ⚠️ Node perms | ⚠️ With patches |
| Views integration | ⚠️ Custom entity | ✅ Node-based | ✅ Full |
| Remote storage (S3) | ❌ No | ✅ Flysystem | ⚠️ Limited |
| Stability | ⚠️ Alpha | ✅ Stable | ✅ Stable (mostly) |
| Group integration | ⚠️ Manual work | ✅ Via node perms | ✅ Via entity refs |
| Setup complexity | ✅ Low | ✅ Low | ⚠️ High |

**Legend:** ✅ Good | ⚠️ Partial/Caveats | ❌ Not supported

---

## Recommendation

Based on AVC's requirements for collaborative file management within Open Social groups, the following recommendations are provided in order of preference:

### Primary Recommendation: Media + Taxonomy

The **Media + Taxonomy + File Field Paths** approach is recommended as the primary solution despite its higher setup complexity. This approach offers the deepest integration with Open Social and Drupal's existing content architecture, making it the most sustainable long-term choice.

**Rationale:**

1. Media entities work seamlessly with Views, enabling custom dashboards and file listings
2. Taxonomy-based folders integrate with Open Social's existing group and permission structures
3. Users can create folders when given taxonomy term creation permissions
4. Core modules (Media, Media Library) are stable and well-maintained
5. Can be extended with `permissions_by_entity` for granular folder-level access

### Alternative: Filebrowser for Admin-Managed Folders

If the requirement shifts to admin-controlled shared folders rather than user-managed file spaces, **Filebrowser** provides a simpler, more stable solution. This would be appropriate if each Open Social group has a dedicated folder managed by group administrators rather than individual members.

### Future Consideration: FolderShare

**FolderShare** offers the best user experience but should be reconsidered once it reaches a stable release. Its alpha status and database limitations (no PostgreSQL) make it unsuitable for production use in AVC at this time. Monitor the project for stable releases.

---

## Next Steps

1. **Confirm Requirements:** Verify whether users need to create their own folders or if admin-managed group folders are sufficient

2. **Prototype:** Set up a test instance via NWP with the recommended Media + Taxonomy approach
   ```bash
   nwp install avc-test
   cd avc-test
   ddev composer require drupal/media_directories drupal/filefield_paths
   ddev drush en media_directories_ui media_directories_editor -y
   ```

3. **Configure jsTree:** Install Media Directories with jsTree library for folder browser UI

4. **Test Group Integration:** Verify folder access works correctly with Open Social group permissions

5. **User Testing:** Gather feedback from AVC pilot users on folder management workflow

6. **Document Configuration:** Add setup steps to NWP installation scripts for AVC

---

## Related Repositories

| Repository | Purpose |
|------------|---------|
| [rjzaar/avcgs](https://github.com/rjzaar/avcgs) | AVC installation profile and custom modules |
| [rjzaar/workflow_assignment](https://github.com/rjzaar/workflow_assignment) | General-purpose workflow assignment module |
| [rjzaar/nwp](https://github.com/rjzaar/nwp) | NWP site management tools and scripts |

---

## Contact

For questions or to discuss this proposal, please contact:

**Rob Zaar**  
Email: rjzaar@gmail.com  
GitHub: [github.com/rjzaar](https://github.com/rjzaar)

---

*This document was prepared for the AV Commons project, a collaborative workflow platform for Apostoli Viae built on Open Social.*