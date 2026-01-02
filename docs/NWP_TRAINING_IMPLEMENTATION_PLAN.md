# NWP Training System Implementation Plan

A phased, numbered implementation plan for building an automated NWP training system without video dependencies.

---

## Overview

This plan uses **text-based interactive learning** instead of videos:
- Asciinema terminal recordings (replayable text, not video)
- Interactive sandbox environments
- Auto-graded coding exercises
- Markdown-based content with diagrams

**Total Phases:** 6
**Estimated Duration:** 20 weeks (flexible, can be extended)

---

## Phase 1: Infrastructure Setup

**Goal:** Establish the Moodle LMS with CodeRunner for automated assessment

### 1.1 Moodle Installation
- [ ] 1.1.1 Create dedicated Moodle site using NWP's `dm` recipe
- [ ] 1.1.2 Configure site name: `learn.nwpcode.org` (or similar)
- [ ] 1.1.3 Set up SSL certificate via Cloudflare
- [ ] 1.1.4 Configure admin account and basic settings
- [ ] 1.1.5 Install essential plugins:
  - Boost theme (clean, modern interface)
  - Completion Progress block
  - Level Up XP (gamification)

### 1.2 CodeRunner Setup
- [ ] 1.2.1 Install CodeRunner question type plugin
- [ ] 1.2.2 Set up Jobe sandbox server (separate Docker container)
- [ ] 1.2.3 Configure Jobe to support bash script execution
- [ ] 1.2.4 Test basic bash question: "Write command to list files"
- [ ] 1.2.5 Configure security settings and rate limits
- [ ] 1.2.6 Document Jobe server maintenance procedures

### 1.3 Course Structure
- [ ] 1.3.1 Create main course: "NWP Developer Training"
- [ ] 1.3.2 Set up course sections matching skill tree:
  - Section 1: Fundamentals
  - Section 2: Core Operations
  - Section 3: Deployment Pipeline
  - Section 4: Advanced Topics
- [ ] 1.3.3 Configure course completion tracking
- [ ] 1.3.4 Set up prerequisite requirements between sections

### 1.4 Badge System
- [ ] 1.4.1 Create badge images (simple icons, can use free icon libraries)
- [ ] 1.4.2 Configure badges in Moodle:
  - NWP Initiate (complete Fundamentals)
  - Site Manager (complete Core Operations)
  - Deployment Pro (complete Deployment)
  - NWP Expert (complete all + 90% score)
- [ ] 1.4.3 Link badges to course completion criteria

**Phase 1 Deliverables:**
- Working Moodle instance with CodeRunner
- Course structure with 4 main sections
- Badge system configured
- Jobe sandbox tested and operational

---

## Phase 2: Practice Environment

**Goal:** Create a safe, resettable NWP sandbox for hands-on practice

### 2.1 Docker Practice Environment
- [ ] 2.1.1 Create Dockerfile for NWP practice environment:
  ```
  - Ubuntu base with Docker-in-Docker
  - NWP pre-installed
  - 3 example sites pre-configured (nwp1, nwp2, nwp3)
  - Auto-reset capability
  ```
- [ ] 2.1.2 Create docker-compose.yml for practice stack
- [ ] 2.1.3 Add practice environment to NWP repository
- [ ] 2.1.4 Document local practice setup instructions
- [ ] 2.1.5 Test full reset/restore cycle

### 2.2 Practice Mode for NWP
- [ ] 2.2.1 Add `--practice` flag to key NWP scripts
- [ ] 2.2.2 Practice mode features:
  - Creates isolated practice sites (prefix: `practice_`)
  - Validates user actions against expected outcomes
  - Provides hints on incorrect commands
  - Auto-cleanup after session
- [ ] 2.2.3 Create practice scenarios configuration file
- [ ] 2.2.4 Implement practice validation library

### 2.3 Web-Based Sandbox (Optional - for hosted solution)
- [ ] 2.3.1 Evaluate hosting options:
  - Self-hosted via Linode
  - Instruqt integration
  - Codio integration
- [ ] 2.3.2 Create sandbox provisioning scripts
- [ ] 2.3.3 Implement session timeout and cleanup
- [ ] 2.3.4 Add sandbox access to Moodle course

**Phase 2 Deliverables:**
- Docker-based practice environment
- `--practice` mode in NWP scripts
- Documentation for local practice setup
- (Optional) Web-based sandbox access

---

## Phase 3: Content Creation - Fundamentals

**Goal:** Create all learning content for the Fundamentals section

### 3.1 Module F1: Introduction to NWP
- [ ] 3.1.1 Write learning objectives
- [ ] 3.1.2 Create content page: "What is NWP?"
  - Purpose and benefits
  - Architecture diagram (draw.io)
  - Key concepts glossary
- [ ] 3.1.3 Create content page: "NWP Directory Structure"
  - Annotated directory tree
  - File purposes explained
- [ ] 3.1.4 Create asciinema recording: Exploring NWP
- [ ] 3.1.5 Create quiz: NWP Concepts (10 questions)
- [ ] 3.1.6 Create CodeRunner exercise: Navigate to correct directories

### 3.2 Module F2: Prerequisites Check
- [ ] 3.2.1 Create content page: "Required Knowledge"
  - Linux command line basics
  - Docker concepts
  - Git fundamentals
- [ ] 3.2.2 Create diagnostic quiz: Prerequisites (15 questions)
- [ ] 3.2.3 Create remedial links for each prerequisite topic
- [ ] 3.2.4 Set quiz as gateway (must pass to continue)

### 3.3 Module F3: Setup & Installation
- [ ] 3.3.1 Create content page: "Running setup.sh"
  - Step-by-step walkthrough
  - Expected output examples
  - Troubleshooting common issues
- [ ] 3.3.2 Create content page: "Understanding cnwp.yml"
  - YAML structure explanation
  - Recipe definition syntax
  - Settings hierarchy
- [ ] 3.3.3 Create asciinema recording: Full setup process
- [ ] 3.3.4 Create asciinema recording: First site installation
- [ ] 3.3.5 Create CodeRunner exercises:
  - Write a valid recipe definition
  - Identify errors in cnwp.yml
  - Run installation command
- [ ] 3.3.6 Create practice task: Install your first site
- [ ] 3.3.7 Create quiz: Setup & Configuration (10 questions)

### 3.4 Module F4: Basic Site Operations
- [ ] 3.4.1 Create content page: "Starting and Stopping Sites"
- [ ] 3.4.2 Create content page: "Accessing Your Site"
- [ ] 3.4.3 Create content page: "DDEV Integration"
- [ ] 3.4.4 Create asciinema recordings for each operation
- [ ] 3.4.5 Create CodeRunner exercises (5 exercises)
- [ ] 3.4.6 Create practice task: Site lifecycle management
- [ ] 3.4.7 Create section quiz: Fundamentals Review (20 questions)

### 3.5 Fundamentals Assessment
- [ ] 3.5.1 Create practical assessment:
  - Install a site from recipe
  - Verify site is running
  - Access admin interface
- [ ] 3.5.2 Set 80% passing threshold
- [ ] 3.5.3 Link to "NWP Initiate" badge

**Phase 3 Deliverables:**
- 4 complete modules with all content
- 15+ asciinema terminal recordings
- 20+ CodeRunner exercises
- 4 quizzes + 1 practical assessment
- Fundamentals section fully functional

---

## Phase 4: Content Creation - Core Operations

**Goal:** Create learning content for backup, restore, copy, delete, and mode management

### 4.1 Module C1: Backup Operations
- [ ] 4.1.1 Create content page: "backup.sh Overview"
- [ ] 4.1.2 Create content page: "Full vs Database-Only Backups"
- [ ] 4.1.3 Create content page: "Backup Flags and Options"
  - `-b` flag (database-only)
  - `-y` flag (auto-confirm)
  - Combined flags
- [ ] 4.1.4 Create asciinema recordings:
  - Full backup
  - Database-only backup
  - Backup with description
- [ ] 4.1.5 Create CodeRunner exercises (8 exercises):
  - Write correct backup commands
  - Identify backup flag combinations
  - Parse backup output
- [ ] 4.1.6 Create practice task: Backup workflow
- [ ] 4.1.7 Create quiz: Backup Mastery (10 questions)

### 4.2 Module C2: Restore Operations
- [ ] 4.2.1 Create content page: "restore.sh Overview"
- [ ] 4.2.2 Create content page: "Restore Options and Flags"
- [ ] 4.2.3 Create content page: "Cross-Site Restoration"
- [ ] 4.2.4 Create asciinema recordings (4 recordings)
- [ ] 4.2.5 Create CodeRunner exercises (6 exercises)
- [ ] 4.2.6 Create practice task: Restore from backup
- [ ] 4.2.7 Create quiz: Restore Operations (8 questions)

### 4.3 Module C3: Copy Operations
- [ ] 4.3.1 Create content page: "copy.sh Overview"
- [ ] 4.3.2 Create content page: "Full Copy vs Files-Only"
- [ ] 4.3.3 Create asciinema recordings (3 recordings)
- [ ] 4.3.4 Create CodeRunner exercises (5 exercises)
- [ ] 4.3.5 Create practice task: Clone a site
- [ ] 4.3.6 Create quiz: Copy Operations (6 questions)

### 4.4 Module C4: Delete Operations
- [ ] 4.4.1 Create content page: "delete.sh Overview"
- [ ] 4.4.2 Create content page: "Safety Features"
- [ ] 4.4.3 Create content page: "Backup Before Delete"
- [ ] 4.4.4 Create asciinema recordings (3 recordings)
- [ ] 4.4.5 Create CodeRunner exercises (4 exercises)
- [ ] 4.4.6 Create practice task: Safe deletion workflow
- [ ] 4.4.7 Create quiz: Delete Operations (6 questions)

### 4.5 Module C5: Development Modes
- [ ] 4.5.1 Create content page: "make.sh Overview"
- [ ] 4.5.2 Create content page: "Dev Mode vs Production Mode"
- [ ] 4.5.3 Create content page: "When to Use Each Mode"
- [ ] 4.5.4 Create asciinema recordings (4 recordings)
- [ ] 4.5.5 Create CodeRunner exercises (5 exercises)
- [ ] 4.5.6 Create practice task: Mode switching
- [ ] 4.5.7 Create quiz: Development Modes (8 questions)

### 4.6 Module C6: Status & Monitoring
- [ ] 4.6.1 Create content page: "status.sh Overview"
- [ ] 4.6.2 Create content page: "Reading Status Output"
- [ ] 4.6.3 Create content page: "Health Checks"
- [ ] 4.6.4 Create asciinema recordings (3 recordings)
- [ ] 4.6.5 Create CodeRunner exercises (4 exercises)
- [ ] 4.6.6 Create quiz: Status Interpretation (8 questions)

### 4.7 Core Operations Assessment
- [ ] 4.7.1 Create practical assessment:
  - Backup a site
  - Restore to a new location
  - Copy a site
  - Toggle development mode
  - Check status
- [ ] 4.7.2 Set 85% passing threshold
- [ ] 4.7.3 Link to "Site Manager" badge

**Phase 4 Deliverables:**
- 6 complete modules
- 20+ asciinema recordings
- 32+ CodeRunner exercises
- 6 module quizzes + 1 practical assessment
- Core Operations section fully functional

---

## Phase 5: Content Creation - Deployment

**Goal:** Create learning content for the deployment pipeline

### 5.1 Module D1: Environment Concepts
- [ ] 5.1.1 Create content page: "Development, Staging, Production"
- [ ] 5.1.2 Create content page: "Environment Naming Conventions"
- [ ] 5.1.3 Create content page: "Deployment Pipeline Overview"
- [ ] 5.1.4 Create diagram: Deployment flow
- [ ] 5.1.5 Create quiz: Environment Concepts (10 questions)

### 5.2 Module D2: Dev to Staging
- [ ] 5.2.1 Create content page: "dev2stg.sh Overview"
- [ ] 5.2.2 Create content page: "Staging Environment Setup"
- [ ] 5.2.3 Create asciinema recordings (4 recordings)
- [ ] 5.2.4 Create CodeRunner exercises (6 exercises)
- [ ] 5.2.5 Create practice task: Deploy to staging
- [ ] 5.2.6 Create quiz: Dev to Staging (8 questions)

### 5.3 Module D3: Staging to Production
- [ ] 5.3.1 Create content page: "stg2prod.sh Overview"
- [ ] 5.3.2 Create content page: "Production Safety Checklist"
- [ ] 5.3.3 Create content page: "Rollback Procedures"
- [ ] 5.3.4 Create asciinema recordings (4 recordings)
- [ ] 5.3.5 Create CodeRunner exercises (6 exercises)
- [ ] 5.3.6 Create practice task: Production deployment
- [ ] 5.3.7 Create quiz: Production Deployment (10 questions)

### 5.4 Module D4: Production to Staging Sync
- [ ] 5.4.1 Create content page: "prod2stg.sh Overview"
- [ ] 5.4.2 Create content page: "When to Sync Back"
- [ ] 5.4.3 Create asciinema recordings (2 recordings)
- [ ] 5.4.4 Create CodeRunner exercises (4 exercises)
- [ ] 5.4.5 Create quiz: Sync Operations (6 questions)

### 5.5 Module D5: Live Server Deployment
- [ ] 5.5.1 Create content page: "live.sh Overview"
- [ ] 5.5.2 Create content page: "Linode Integration"
- [ ] 5.5.3 Create content page: "DNS and SSL Setup"
- [ ] 5.5.4 Create asciinema recordings (4 recordings)
- [ ] 5.5.5 Create CodeRunner exercises (5 exercises)
- [ ] 5.5.6 Create quiz: Live Deployment (10 questions)

### 5.6 Module D6: Security Hardening
- [ ] 5.6.1 Create content page: "security.sh Overview"
- [ ] 5.6.2 Create content page: "Security Modules Installed"
- [ ] 5.6.3 Create content page: "Security Best Practices"
- [ ] 5.6.4 Create asciinema recordings (3 recordings)
- [ ] 5.6.5 Create CodeRunner exercises (4 exercises)
- [ ] 5.6.6 Create quiz: Security Concepts (8 questions)

### 5.7 Deployment Assessment
- [ ] 5.7.1 Create practical assessment:
  - Full deployment pipeline execution
  - Rollback scenario
  - Security hardening
- [ ] 5.7.2 Set 85% passing threshold
- [ ] 5.7.3 Link to "Deployment Pro" badge

**Phase 5 Deliverables:**
- 6 complete modules
- 17+ asciinema recordings
- 25+ CodeRunner exercises
- 6 module quizzes + 1 practical assessment
- Deployment section fully functional

---

## Phase 6: Advanced Topics & Certification

**Goal:** Complete advanced content and implement certification system

### 6.1 Module A1: GitLab Infrastructure
- [ ] 6.1.1 Create content pages for GitLab setup
- [ ] 6.1.2 Create asciinema recordings (4 recordings)
- [ ] 6.1.3 Create CodeRunner exercises (5 exercises)
- [ ] 6.1.4 Create quiz: GitLab Management (10 questions)

### 6.2 Module A2: Linode Deployment
- [ ] 6.2.1 Create content pages for Linode integration
- [ ] 6.2.2 Create asciinema recordings (4 recordings)
- [ ] 6.2.3 Create CodeRunner exercises (5 exercises)
- [ ] 6.2.4 Create quiz: Linode Operations (8 questions)

### 6.3 Module A3: Podcast Infrastructure
- [ ] 6.3.1 Create content pages for Castopod setup
- [ ] 6.3.2 Create asciinema recordings (3 recordings)
- [ ] 6.3.3 Create CodeRunner exercises (4 exercises)
- [ ] 6.3.4 Create quiz: Podcast Setup (6 questions)

### 6.4 Module A4: Custom Development
- [ ] 6.4.1 Create content page: "Creating Custom Recipes"
- [ ] 6.4.2 Create content page: "Understanding Library Functions"
- [ ] 6.4.3 Create content page: "Contributing to NWP"
- [ ] 6.4.4 Create CodeRunner exercises (6 exercises)
- [ ] 6.4.5 Create quiz: Custom Development (10 questions)

### 6.5 Certification System
- [ ] 6.5.1 Create certification exam structure:
  - 50 questions, 2-hour time limit
  - Mixed: multiple choice + CodeRunner
  - 90% passing threshold
- [ ] 6.5.2 Create question bank (100+ questions, randomized selection)
- [ ] 6.5.3 Implement certificate generation:
  - PDF certificate with unique ID
  - QR code for verification
  - Learner name and date
- [ ] 6.5.4 Create verification page on NWP website
- [ ] 6.5.5 Link to "NWP Expert" badge

### 6.6 Spaced Repetition System
- [ ] 6.6.1 Install StudentQuiz plugin or equivalent
- [ ] 6.6.2 Create review quiz pools for each section
- [ ] 6.6.3 Configure automated review reminders:
  - Day 1: Initial learning
  - Day 3: First review
  - Day 7: Second review
  - Day 14: Third review
  - Day 30: Long-term review
- [ ] 6.6.4 Create mixed review quizzes

### 6.7 Final Polish
- [ ] 6.7.1 Review all content for accuracy
- [ ] 6.7.2 Test all CodeRunner exercises
- [ ] 6.7.3 Verify all prerequisites and completion tracking
- [ ] 6.7.4 Create course welcome message
- [ ] 6.7.5 Create course completion message
- [ ] 6.7.6 Set up learner feedback survey

**Phase 6 Deliverables:**
- 4 advanced modules
- Certification exam with 100+ question bank
- Certificate generation system
- Spaced repetition review system
- Complete, polished course

---

## Content Format Standards

### Asciinema Recordings
Instead of videos, use [asciinema](https://asciinema.org/) for terminal recordings:

```bash
# Install asciinema
sudo apt install asciinema

# Record a session
asciinema rec demo-backup.cast

# Upload or embed
asciinema upload demo-backup.cast
```

Benefits:
- Text-based (searchable, accessible)
- Tiny file sizes
- Can be paused, rewound, copied from
- Embeddable in Moodle via iframe

### Content Pages
Use Moodle's Page resource with:
- Clear headings (H2, H3)
- Code blocks with syntax highlighting
- Annotated command examples
- Diagrams (embedded from draw.io)
- Collapsible sections for advanced details

### CodeRunner Question Template
```
Question: Write the command to [task description]

Example:
  Site: nwp5
  Requirement: Database-only backup with auto-confirm

Expected Answer: ./backup.sh -by nwp5

Test Cases:
  1. Contains "backup.sh"
  2. Contains "-b" flag
  3. Contains "-y" flag
  4. Contains "nwp5"
  5. Correct order of arguments
```

### Quiz Question Types
- **Multiple Choice**: Concept understanding
- **Multiple Answer**: Flag combinations
- **Matching**: Command to purpose
- **Short Answer**: Exact command syntax
- **CodeRunner**: Executable code validation

---

## Resource Requirements

### Personnel
| Role | Hours/Week | Duration |
|------|------------|----------|
| Content Author | 10-15 | Phases 3-6 |
| Technical Setup | 5-10 | Phases 1-2 |
| Reviewer | 3-5 | Phases 3-6 |
| Tester | 5-10 | Phase 6 |

### Infrastructure
| Resource | Specification | Cost |
|----------|--------------|------|
| Moodle Server | 4GB RAM, 2 vCPU | ~$20/mo |
| Jobe Sandbox | 2GB RAM, 1 vCPU | ~$10/mo |
| Practice Sandbox | 8GB RAM, 4 vCPU (shared) | ~$40/mo |
| Domain/SSL | learn.nwpcode.org | Included |

### Tools (All Free)
- Moodle LMS
- CodeRunner plugin
- Asciinema
- Draw.io (diagrams)
- Markdown editors

---

## Success Metrics

### Phase Completion Criteria
| Phase | Criteria |
|-------|----------|
| 1 | Moodle operational, CodeRunner tested, badges configured |
| 2 | Practice environment working, reset tested |
| 3 | Fundamentals 100% complete, 5 test users pass |
| 4 | Core Operations 100% complete, 5 test users pass |
| 5 | Deployment 100% complete, 5 test users pass |
| 6 | Certification working, 3 users certified |

### Learning Metrics (Post-Launch)
- Module completion rate: Target >80%
- Average quiz score: Target >75%
- Certification pass rate: Target >60%
- Time to certification: Baseline + improvements
- Learner satisfaction: Target >4/5

---

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| CodeRunner complexity | Start simple, iterate |
| Content takes too long | Prioritize core modules, defer advanced |
| Low engagement | Add gamification early, gather feedback |
| Technical issues | Maintain staging environment for testing |
| Sandbox abuse | Rate limiting, session timeouts, monitoring |

---

## Quick Start Checklist

To begin immediately:

- [ ] Create Moodle site using `./install.sh dm learn`
- [ ] Install CodeRunner from Moodle plugins directory
- [ ] Set up Jobe server (Docker): `docker run -d -p 4000:80 trampgeek/jobeiern`
- [ ] Create first test question in CodeRunner
- [ ] Record first asciinema demo
- [ ] Write Module F1 content

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-01-03 | Initial plan created |
