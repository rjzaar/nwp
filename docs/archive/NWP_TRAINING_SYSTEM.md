# NWP Training System Investigation

A comprehensive analysis of the best approaches to automatically train developers on using NWP, based on cognitive science research and current best practices in technical training.

## Executive Summary

Based on cognitive science research and current best practices, we recommend a **Moodle-based training system** using the **CodeRunner plugin** for automated assessment, combined with:
- Spaced repetition for long-term retention
- Microlearning modules (3-10 minutes each)
- Hands-on sandboxed practice tasks
- Skill tree progression with prerequisites
- Badges and certification

---

## 1. Cognitive Science Foundations

### Spaced Repetition + Retrieval Practice

Research from [Nature Reviews Psychology](https://www.nature.com/articles/s44159-022-00089-1) demonstrates that combining these two techniques creates the most effective learning:

| Principle | Evidence | Application to NWP |
|-----------|----------|-------------------|
| **Spaced Repetition** | Superior long-term learning vs cramming | Review NWP concepts at increasing intervals (1 day → 3 days → 1 week → 2 weeks) |
| **Retrieval Practice** | Active recall strengthens memory significantly | Quiz learners on commands before showing answers |
| **Desirable Difficulty** | Some cognitive effort maximizes retention | Don't make tasks too easy - require problem-solving |

> "Memory consolidation requires time... spaced repetition arranges reviews at critical points of memory decay, compelling learners to exert appropriate retrieval effort." - [Research on Spaced Repetition and AI](https://www.researchgate.net/publication/397538205_Spaced_Repetition_and_Retrieval_Practice_Efficient_Learning_Mechanisms_from_a_Cognitive_Psychology_Perspective_and_Their_Empowerment_by_AI)

### Microlearning Effectiveness

[Research shows](https://www.shiftelearning.com/blog/numbers-dont-lie-why-bite-sized-learning-is-better-for-your-learners-and-you-too):
- **25-60% better retention** than traditional methods
- **80-90% completion rates** vs ~30% for long courses
- **3-7 minute modules** are optimal
- **40-60% less development time** than traditional courses

For developers specifically, [microlearning is especially valuable](https://www.cogentuniversity.com/post/microlearning-for-developers-affordable-bite-sized-training-to-boost-coding-skills-and-productivity) because engineers need to acquire skills quickly without interrupting workflow.

---

## 2. Recommended Platform: Moodle + CodeRunner

### Why Moodle?

[Moodle is the top open-source LMS](https://www.walkme.com/blog/best-open-source-lms-platforms/) with:
- Largest plugin ecosystem
- Self-hosted (you control the data)
- Scales from small to enterprise
- Strong community support
- **NWP already has Moodle infrastructure (dm recipe)**

### CodeRunner Plugin

[CodeRunner](https://coderunner.org.nz/) is perfect for NWP training:

- **Runs student code in a sandbox** (Jobe server)
- **Supports bash scripts** - can test NWP commands directly
- **Automatic grading** with immediate feedback
- **All-or-nothing mode** - students must pass all tests
- **Used on 3500+ Moodle sites** including University of Canterbury (12+ years, millions of submissions)
- **Mini IDE** within questions for testing before submission

Example NWP question:
```
Write the command to backup site 'nwp5' with database-only mode and auto-confirm:

Expected answer: ./backup.sh -by nwp5
Tests: Verify correct flags, correct site name, correct script
```

---

## 3. Recommended Course Structure

### Skill Tree Design

Based on [skill tree learning design](https://medium.com/prodigy-engineering/skill-trees-for-adaptive-learning-729760e5dd00):

```
NWP SKILL TREE
===============

FUNDAMENTALS (Required First)
├── Prerequisites Check
│   ├── Linux Command Line Basics
│   ├── Docker Concepts
│   └── Git Basics
│
├── NWP Setup
│   ├── Running setup.sh
│   ├── Understanding cnwp.yml
│   └── First Site Installation

CORE OPERATIONS (Unlock after Fundamentals)
├── Site Management
│   ├── backup.sh (with -b flag variations)
│   ├── restore.sh
│   ├── copy.sh
│   └── delete.sh
│
├── Development Workflow
│   ├── make.sh (dev/prod modes)
│   ├── status.sh
│   └── modify.sh

DEPLOYMENT (Unlock after Core Operations)
├── Environment Pipeline
│   ├── dev2stg.sh
│   ├── stg2prod.sh
│   └── prod2stg.sh
│
├── Live Deployment
│   ├── live.sh
│   ├── stg2live.sh
│   └── security.sh

ADVANCED (Unlock after Deployment)
├── Infrastructure
│   ├── GitLab Setup
│   ├── Linode Deployment
│   └── Podcast Infrastructure
│
├── Custom Development
│   ├── Creating Custom Recipes
│   ├── Library Functions
│   └── Contributing to NWP
```

### Module Design (Microlearning)

Each topic should follow this pattern:

| Phase | Duration | Content |
|-------|----------|---------|
| **Concept** | 2-3 min | Short video/text explaining the command |
| **Demo** | 2-3 min | Screencast showing real usage |
| **Practice** | 5-10 min | Sandboxed hands-on task |
| **Quiz** | 2-3 min | Retrieval practice questions |
| **Challenge** | 5-15 min | Real-world scenario to solve |

---

## 4. Hands-On Practice Environment

### Option A: Docker-Based Sandbox (Recommended)

Create a pre-configured Docker environment for practice:

```yaml
# Practice environment specs
- NWP pre-installed with example sites
- Safe to experiment (can be reset)
- Accessible via browser (using Codio, Instruqt, or similar)
- Automated validation of task completion
```

[Instruqt](https://instruqt.com/feature/sandbox) and [Codio](https://www.codio.com/virtual-labs/) provide browser-based sandbox environments with automated grading.

### Option B: Local Practice Mode

Add a `--training` mode to NWP that:
- Creates isolated practice sites
- Validates learner actions
- Provides hints when stuck
- Auto-resets on completion

---

## 5. Gamification Strategy

[Meta-analysis of 41 studies](https://www.frontiersin.org/journals/psychology/articles/10.3389/fpsyg.2023.1253549/full) shows gamification has a **large effect size (g = 0.822)** on learning outcomes.

### Recommended Elements

| Element | Purpose | Implementation |
|---------|---------|----------------|
| **Badges** | Achievement recognition | Awarded for completing modules, skill trees |
| **Points** | Progress tracking | Earn points for correct answers, challenge completion |
| **Progress Bar** | Visual motivation | Show % complete for each skill tree branch |
| **Leaderboard** | Optional competition | Can be disabled for anxious learners |
| **Certificates** | Formal recognition | PDF certificate with QR verification |

### Badge Examples for NWP

- **NWP Initiate** - Complete setup and first installation
- **Backup Master** - Complete all backup/restore modules
- **Deployment Pro** - Complete deployment pipeline
- **Security Champion** - Complete security hardening
- **NWP Expert** - Complete all modules with 90%+ scores

[Research shows](https://www.frontiersin.org/journals/education/articles/10.3389/feduc.2024.1429452/full) digital badges enhance intrinsic motivation across all five dimensions, while their impact on extrinsic motivation is minimal (which is good - intrinsic is more sustainable).

---

## 6. Assessment & Certification

### Progressive Assessment

1. **Formative (During Learning)**
   - CodeRunner auto-graded coding questions
   - Multiple choice retrieval practice
   - Immediate feedback

2. **Summative (End of Module)**
   - Practical challenges in sandbox
   - Must achieve 80%+ to proceed

3. **Certification Exam**
   - [Performance-based questions in virtual lab](https://www.isaca.org/credentialing/software-development-fundamentals-certificate) (like ISACA model)
   - Real NWP tasks to complete
   - Time-limited (e.g., 2 hours)
   - Proctored option for formal certification

### Certification Levels

| Level | Requirements | Badge |
|-------|--------------|-------|
| **NWP Fundamentals** | Complete Fundamentals tree, 80%+ score | Bronze |
| **NWP Practitioner** | Complete Core + Deployment, 85%+ score | Silver |
| **NWP Expert** | Complete all trees, 90%+ score, capstone project | Gold |

---

## 7. Spaced Repetition Implementation

### Moodle Plugins for Spaced Repetition

- **[StudentQuiz](https://moodle.org/plugins/mod_studentquiz)** - Learners create and answer questions
- **Custom scheduled quizzes** - Moodle can schedule review sessions

### Review Schedule

```
Day 1:  Learn backup.sh
Day 2:  Quiz on backup.sh (first retrieval)
Day 4:  Quiz on backup.sh + new content
Day 8:  Quiz on backup.sh (spaced retrieval)
Day 16: Mixed review of all backup topics
```

---

## 8. Implementation Roadmap

### Phase 1: Foundation (Weeks 1-4)
- Set up Moodle instance (using dm recipe)
- Install CodeRunner plugin with Jobe sandbox
- Create course structure and skill tree
- Design first 10 microlearning modules (Fundamentals)

### Phase 2: Content Development (Weeks 5-12)
- Create all module content:
  - Video screencasts (2-3 min each)
  - Written guides with examples
  - CodeRunner questions
  - Sandbox practice tasks
- Implement badge system
- Create progress tracking

### Phase 3: Testing & Refinement (Weeks 13-16)
- Pilot with 5-10 developers
- Gather feedback
- Refine based on completion rates and scores
- Add more practice scenarios

### Phase 4: Certification (Weeks 17-20)
- Design certification exams
- Create capstone projects
- Implement certificate generation
- Launch publicly

---

## 9. Content Outline for NWP Training

### Module 1: Introduction to NWP (15 min total)
- What is NWP? (2 min video)
- Architecture overview (3 min)
- Prerequisites check (quiz)
- Demo: Exploring the NWP directory (5 min)
- Practice: Navigate NWP structure (5 min)

### Module 2: Setup & First Installation (20 min)
- Running setup.sh (3 min video)
- Understanding cnwp.yml (5 min)
- Practice: Install your first site (10 min sandbox)
- Quiz: Setup concepts (2 min)

### Module 3: Backup Operations (25 min)
- backup.sh overview (3 min)
- Full vs database-only backups (3 min)
- Demo: Backup scenarios (5 min)
- Practice: Perform backups (10 min sandbox)
- Challenge: Backup before migration (4 min)

### Module 4: Restore Operations (20 min)
- restore.sh overview (3 min)
- Restore options and flags (3 min)
- Practice: Restore from backup (10 min sandbox)
- Quiz: Backup/Restore concepts (4 min)

### Module 5: Site Copying (15 min)
- copy.sh overview (2 min)
- Full copy vs files-only (3 min)
- Practice: Copy a site (8 min sandbox)
- Quiz: Copy operations (2 min)

### Module 6: Site Deletion (15 min)
- delete.sh overview (2 min)
- Safety features and flags (3 min)
- Practice: Safe deletion workflow (8 min sandbox)
- Quiz: Deletion concepts (2 min)

### Module 7: Development Modes (20 min)
- make.sh overview (3 min)
- Dev mode vs production mode (5 min)
- Practice: Toggle modes (8 min sandbox)
- Quiz: Mode concepts (4 min)

### Module 8: Status & Monitoring (15 min)
- status.sh overview (3 min)
- Reading status output (5 min)
- Practice: Check site health (5 min)
- Quiz: Status interpretation (2 min)

### Module 9: Dev to Staging Deployment (25 min)
- dev2stg.sh overview (3 min)
- Environment naming conventions (3 min)
- Demo: Full deployment workflow (5 min)
- Practice: Deploy to staging (10 min sandbox)
- Challenge: Complete deployment cycle (4 min)

### Module 10: Production Deployment (30 min)
- stg2prod.sh and prod2stg.sh overview (5 min)
- Safety considerations (5 min)
- Demo: Production workflow (5 min)
- Practice: Production deployment (12 min sandbox)
- Quiz: Production concepts (3 min)

*(Continue for remaining features: live deployment, security, GitLab, Linode, podcasts, custom recipes...)*

---

## 10. Alternative Platforms Considered

| Platform | Pros | Cons | Verdict |
|----------|------|------|---------|
| **Moodle** | Full-featured, CodeRunner, self-hosted | Requires setup | Recommended |
| **Open edX** | Scales massively, MOOC-ready | Complex setup, overkill for small team | Consider for public courses |
| **Chamilo** | Simple, fast setup | Less plugin ecosystem | Backup option |
| **Custom (React + Docker)** | Full control | Significant dev effort | Only if specific needs |

---

## 11. Technical Requirements

### Moodle Server
- PHP 8.1+
- MariaDB/MySQL or PostgreSQL
- 4GB RAM minimum (8GB recommended)
- HTTPS enabled

### Jobe Sandbox Server (for CodeRunner)
- Separate Linux server (security isolation)
- Docker or native installation
- Languages: Bash, Python (for testing)
- Firewall: Only accessible from Moodle server

### Content Creation Tools
- Screen recording: OBS Studio (free)
- Video editing: DaVinci Resolve (free)
- Diagrams: draw.io (free)
- Documentation: Markdown

---

## 12. Success Metrics

### Learning Outcomes
- Module completion rate (target: >80%)
- Quiz scores (target: >75% average)
- Time to certification (baseline measurement)
- Skill retention (30-day follow-up quiz)

### Engagement Metrics
- Daily active learners
- Average session duration
- Badge achievement rate
- Course dropout points

### Business Outcomes
- Reduction in support questions
- Time for new developers to become productive
- Quality of NWP contributions from trained developers

---

## Summary Recommendation

**Use Moodle with CodeRunner** because:

1. You already have Moodle in NWP (dm recipe)
2. CodeRunner can test bash scripts directly
3. Strong cognitive science alignment (spaced repetition, retrieval practice)
4. Microlearning modules (3-10 min) proven effective
5. Built-in gamification (badges, completion tracking)
6. Self-hosted = full control
7. Certification path with practical assessments

**Key Success Factors:**
- Keep modules short (3-10 min)
- Heavy emphasis on hands-on practice (70% of learning)
- Spaced review quizzes
- Clear skill tree progression
- Immediate feedback on all activities

---

## References

- [Nature Reviews Psychology - Science of Effective Learning](https://www.nature.com/articles/s44159-022-00089-1)
- [Spaced Repetition and Retrieval Practice Research](https://www.researchgate.net/publication/397538205_Spaced_Repetition_and_Retrieval_Practice_Efficient_Learning_Mechanisms_from_a_Cognitive_Psychology_Perspective_and_Their_Empowerment_by_AI)
- [Best Open Source LMS Platforms 2025](https://www.walkme.com/blog/best-open-source-lms-platforms/)
- [CodeRunner Moodle Plugin](https://coderunner.org.nz/)
- [Gamification Meta-Analysis](https://www.frontiersin.org/journals/psychology/articles/10.3389/fpsyg.2023.1253549/full)
- [Digital Badges and Motivation Research](https://www.frontiersin.org/journals/education/articles/10.3389/feduc.2024.1429452/full)
- [Microlearning Statistics 2025](https://www.engageli.com/blog/20-microlearning-statistics-in-2025)
- [Microlearning for Developers](https://www.cogentuniversity.com/post/microlearning-for-developers-affordable-bite-sized-training-to-boost-coding-skills-and-productivity)
- [Codio Virtual Labs](https://www.codio.com/virtual-labs/)
- [Instruqt Sandbox Environments](https://instruqt.com/feature/sandbox)
- [Skill Trees for Adaptive Learning](https://medium.com/prodigy-engineering/skill-trees-for-adaptive-learning-729760e5dd00)
- [ISACA Performance-Based Certification](https://www.isaca.org/credentialing/software-development-fundamentals-certificate)
- [Learning Paths Design](https://www.proprofstraining.com/blog/learning-paths/)
