# Moodle Course Creation Guide for Claude

## Overview

This guide documents the complete process for creating Moodle courses, importing questions, and building quizzes. It includes technical implementation details, cognitive science principles for effective learning design, and troubleshooting strategies.

**Critical Learning**: Always use Moodle's official APIs rather than manual database manipulation. The quiz structure in Moodle 4.x is complex and requires proper API usage.

---

## Table of Contents

1. [Moodle Database Architecture](#moodle-database-architecture)
2. [Course Creation Workflow](#course-creation-workflow)
3. [Question Bank Management](#question-bank-management)
4. [Quiz Creation (The Correct Way)](#quiz-creation-the-correct-way)
5. [Cognitive Science Principles](#cognitive-science-principles)
6. [Common Pitfalls](#common-pitfalls)
7. [Troubleshooting Guide](#troubleshooting-guide)
8. [Complete Example Scripts](#complete-example-scripts)

---

## Moodle Database Architecture

### Core Tables You Need to Understand

#### Questions Structure (Moodle 4.x+)
```
question_bank_entries (qbe)
  ├─> question_versions (qv)
  │     └─> question (q)
  └─> question_categories (qc)
```

**Key Insight**: Questions are versioned. Each question_bank_entry can have multiple versions.

#### Quiz Structure
```
quiz
  ├─> quiz_slots (qs)
  │     ├─> question_references (qr) [links to question_bank_entries]
  │     └─> quiz_grades_items
  ├─> quiz_sections
  └─> question_set_references (qsr) [important metadata]
```

#### Critical Tables

| Table | Purpose | Key Fields |
|-------|---------|------------|
| `question` | Actual question data | id, qtype, name, questiontext |
| `question_bank_entries` | Question bank entries | id, questioncategoryid |
| `question_versions` | Version control | questionbankentryid, questionid, version |
| `question_categories` | Organizes questions | id, contextid, name |
| `question_references` | Links slots to questions | itemid (slot id), questionbankentryid, version |
| `question_set_references` | Quiz-level metadata | itemid (quiz id), component, questionarea |
| `quiz_slots` | Question slots in quiz | id, quizid, slot, page, maxmark |
| `question_answers` | Answer options | question, answer, fraction, feedback |

#### Question Type-Specific Tables

Each question type requires additional configuration:

- **True/False**: `qtype_truefalse` (trueanswer, falseanswer)
- **Short Answer**: `qtype_shortanswer_options` (usecase)
- **Multiple Choice**: `qtype_multichoice_options` (single, shuffleanswers, answernumbering)
- **Matching**: `qtype_match_options` (shuffleanswers, subquestions)

---

## Course Creation Workflow

### Method 1: Import Existing Backup (Recommended)

1. **Prepare backup file**:
   ```bash
   # Verify it's a valid ZIP (not tar.gz)
   file backup.mbz

   # If tar.gz, convert it
   mkdir extracted
   tar -xzf backup.mbz -C extracted/
   cd extracted

   # Add missing XML files if needed
   cat > roles.xml << 'EOF'
   <?xml version="1.0" encoding="UTF-8"?>
   <roles>
     <role_overrides></role_overrides>
     <role_assignments></role_assignments>
   </roles>
   EOF

   # Repeat for: groups.xml, scales.xml, outcomes.xml, grades.xml

   # Repackage as ZIP
   zip -r ../backup_fixed.mbz *
   ```

2. **Import via Moodle UI** (easiest):
   - Navigate to Site Administration > Courses > Restore Course
   - Upload your .mbz file
   - Follow the wizard

3. **Import via CLI** (for automation):
   ```bash
   ddev exec php admin/cli/restore_backup.php \
     --file=/path/to/backup.mbz \
     --categoryid=1 \
     --shortname=COURSECODE
   ```

### Method 2: Create New Course Programmatically

```php
<?php
define('CLI_SCRIPT', true);
require_once('/var/www/html/config.php');
require_once($CFG->dirroot . '/course/lib.php');

// Create course
$course = new stdClass();
$course->fullname = 'Course Full Name';
$course->shortname = 'SHORTNAME';
$course->category = 1; // Course category ID
$course->summary = 'Course description';
$course->summaryformat = FORMAT_HTML;
$course->format = 'topics'; // or 'weeks', 'social'
$course->numsections = 10;
$course->visible = 1;

$course = create_course($course);
echo "Created course ID: {$course->id}\n";
```

---

## Question Bank Management

### Understanding Question Structure

Each question requires:
1. Entry in `question_bank_entries`
2. Entry in `question_versions` (linking entry to question)
3. Entry in `question` (the actual question)
4. Entries in `question_answers` (for most question types)
5. Type-specific options table entry

### Creating Questions from Moodle XML

```php
<?php
define('CLI_SCRIPT', true);
require_once('/var/www/html/config.php');
require_once($CFG->dirroot . '/question/format/xml/format.php');

// Load XML
$xml = simplexml_load_file('questions.xml');
$coursecontext = context_course::instance($courseid);

// Get or create question category
$category = $DB->get_record('question_categories', ['name' => 'Imported Questions']);
if (!$category) {
    $category = new stdClass();
    $category->name = 'Imported Questions';
    $category->contextid = $coursecontext->id;
    $category->info = 'Imported questions';
    $category->infoformat = FORMAT_HTML;
    $category->stamp = make_unique_id_code();
    $category->parent = 0;
    $category->sortorder = 999;
    $category->idnumber = null;
    $categoryid = $DB->insert_record('question_categories', $category);
} else {
    $categoryid = $category->id;
}

// Import each question
foreach ($xml->question as $qxml) {
    $qtype = (string)$qxml['type'];

    // 1. Create question bank entry
    $entry = new stdClass();
    $entry->questioncategoryid = $categoryid;
    $entry->idnumber = null;
    $entry->ownerid = 2; // Admin user
    $entryid = $DB->insert_record('question_bank_entries', $entry);

    // 2. Create question
    $question = new stdClass();
    $question->category = $categoryid;
    $question->parent = 0;
    $question->name = (string)$qxml->name->text;
    $question->questiontext = (string)$qxml->questiontext->text;
    $question->questiontextformat = FORMAT_HTML;
    $question->generalfeedback = '';
    $question->generalfeedbackformat = FORMAT_HTML;
    $question->defaultmark = 1.0;
    $question->penalty = 0.3333333;
    $question->qtype = $qtype;
    $question->length = 1;
    $question->stamp = make_unique_id_code();
    $question->version = make_unique_id_code();
    $question->hidden = 0;
    $question->timecreated = time();
    $question->timemodified = time();
    $question->createdby = 2;
    $question->modifiedby = 2;

    $questionid = $DB->insert_record('question', $question);

    // 3. Create question version
    $version = new stdClass();
    $version->questionbankentryid = $entryid;
    $version->version = 1;
    $version->questionid = $questionid;
    $version->status = 'ready';
    $DB->insert_record('question_versions', $version);

    // 4. Add answers
    foreach ($qxml->answer as $axml) {
        $answer = new stdClass();
        $answer->question = $questionid;
        $answer->answer = (string)$axml->text;
        $answer->answerformat = FORMAT_HTML;
        $answer->fraction = (float)$axml['fraction'] / 100;
        $answer->feedback = (string)$axml->feedback->text;
        $answer->feedbackformat = FORMAT_HTML;
        $DB->insert_record('question_answers', $answer);
    }

    // 5. Add type-specific options
    if ($qtype == 'truefalse') {
        $answers = $DB->get_records('question_answers',
            ['question' => $questionid], 'fraction DESC');
        $trueid = 0;
        $falseid = 0;
        foreach ($answers as $ans) {
            if ($ans->fraction > 0) $trueid = $ans->id;
            else $falseid = $ans->id;
        }

        $tf = new stdClass();
        $tf->question = $questionid;
        $tf->trueanswer = $trueid;
        $tf->falseanswer = $falseid;
        $tf->showstandardinstruction = 1;
        $DB->insert_record('question_truefalse', $tf);

    } elseif ($qtype == 'shortanswer') {
        $sa = new stdClass();
        $sa->questionid = $questionid;
        $sa->usecase = 0;
        $DB->insert_record('qtype_shortanswer_options', $sa);

    } elseif ($qtype == 'multichoice') {
        $mc = new stdClass();
        $mc->questionid = $questionid;
        $mc->single = 1; // Single answer
        $mc->shuffleanswers = 1;
        $mc->answernumbering = 'abc';
        $mc->correctfeedback = 'Correct!';
        $mc->correctfeedbackformat = FORMAT_HTML;
        $mc->partiallycorrectfeedback = 'Partially correct.';
        $mc->partiallycorrectfeedbackformat = FORMAT_HTML;
        $mc->incorrectfeedback = 'Incorrect.';
        $mc->incorrectfeedbackformat = FORMAT_HTML;
        $mc->shownumcorrect = 1;
        $DB->insert_record('qtype_multichoice_options', $mc);
    }

    echo "Imported question: {$question->name} (Entry ID: {$entryid})\n";
}

purge_all_caches();
```

---

## Quiz Creation (The Correct Way)

### ⚠️ CRITICAL: Use Moodle APIs, Not Direct SQL

**DO NOT** manually insert into `quiz_slots` and `question_references`. This leads to broken quizzes where Moodle tries to use slot IDs as question IDs (e.g., 's114' error).

### The Correct Method

```php
<?php
define('CLI_SCRIPT', true);
require_once('/var/www/html/config.php');
require_once($CFG->dirroot . '/mod/quiz/lib.php');
require_once($CFG->dirroot . '/mod/quiz/locallib.php');
require_once($CFG->dirroot . '/course/lib.php');

$courseid = 8;
$coursecontext = context_course::instance($courseid);

// 1. Create quiz record
$quiz = new stdClass();
$quiz->course = $courseid;
$quiz->name = 'My Quiz Title';
$quiz->intro = '<p>Quiz description</p>';
$quiz->introformat = FORMAT_HTML;
$quiz->timeopen = 0;
$quiz->timeclose = 0;
$quiz->timelimit = 0;
$quiz->overduehandling = 'autosubmit';
$quiz->graceperiod = 0;
$quiz->preferredbehaviour = 'deferredfeedback';
$quiz->canredoquestions = 0;
$quiz->attempts = 0; // 0 = unlimited
$quiz->attemptonlast = 0;
$quiz->grademethod = 1; // Highest grade
$quiz->decimalpoints = 2;
$quiz->questiondecimalpoints = -1;
$quiz->reviewattempt = 69904;
$quiz->reviewcorrectness = 4368;
$quiz->reviewmaxmarks = 0;
$quiz->reviewmarks = 4368;
$quiz->reviewspecificfeedback = 4368;
$quiz->reviewgeneralfeedback = 4368;
$quiz->reviewrightanswer = 4368;
$quiz->reviewoverallfeedback = 4368;
$quiz->questionsperpage = 1;
$quiz->navmethod = 'free';
$quiz->shuffleanswers = 1;
$quiz->sumgrades = 10; // Number of questions
$quiz->grade = 100;
$quiz->timecreated = time();
$quiz->timemodified = time();
$quiz->password = '';
$quiz->subnet = '';
$quiz->browsersecurity = '-';
$quiz->delay1 = 0;
$quiz->delay2 = 0;
$quiz->showuserpicture = 0;
$quiz->showblocks = 0;
$quiz->completionattemptsexhausted = 0;
$quiz->completionminattempts = 0;
$quiz->allowofflineattempts = 0;

$quizid = $DB->insert_record('quiz', $quiz);
$quiz->id = $quizid;

echo "Created quiz ID: {$quizid}\n";

// 2. Create course module
$cm = new stdClass();
$cm->course = $courseid;
$cm->module = $DB->get_field('modules', 'id', ['name' => 'quiz']);
$cm->instance = $quizid;
$cm->section = 1; // Section number
$cm->visible = 1;
$cm->visibleoncoursepage = 1;
$cm->visibleold = 1;
$cm->groupmode = 0;
$cm->groupingid = 0;
$cm->completion = 0;
$cm->completionview = 0;
$cm->completionexpected = 0;
$cm->showdescription = 0;
$cm->availability = null;
$cm->deletioninprogress = 0;

$cmid = add_course_module($cm);
$cm->id = $cmid;

// Add to course section
course_add_cm_to_section($courseid, $cmid, $cm->section);

echo "Created course module ID: {$cmid}\n";

// 3. Create grade item
quiz_grade_item_update($quiz);

// 4. Create quiz section
$section = new stdClass();
$section->quizid = $quizid;
$section->firstslot = 1;
$section->heading = '';
$section->shufflequestions = 0;
$DB->insert_record('quiz_sections', $section);

// 5. Add questions using Moodle API
// Question bank entry IDs
$question_entries = [71, 72, 73, 74, 75, 76, 77, 78, 79, 80];

foreach ($question_entries as $entryid) {
    // THIS IS THE CORRECT WAY
    quiz_add_quiz_question($entryid, $quiz, 0, 1);
    echo "Added question entry {$entryid}\n";
}

// 6. Fix missing version fields (quiz_add_quiz_question doesn't always set this)
$refs = $DB->get_records_sql("
    SELECT qr.*
    FROM {question_references} qr
    JOIN {quiz_slots} qs ON qs.id = qr.itemid
    WHERE qs.quizid = ?
    AND qr.component = 'mod_quiz'
    AND qr.questionarea = 'slot'
    AND (qr.version IS NULL OR qr.version = '' OR qr.version = 0)
", [$quizid]);

foreach ($refs as $ref) {
    $DB->set_field('question_references', 'version', 1, ['id' => $ref->id]);
}
echo "Fixed " . count($refs) . " version fields\n";

// 7. Create question_set_reference
$setref = new stdClass();
$setref->usingcontextid = $coursecontext->id;
$setref->component = 'mod_quiz';
$setref->questionarea = 'slot';
$setref->itemid = $quizid;
$setref->questionscontextid = $coursecontext->id;
$DB->insert_record('question_set_references', $setref);

echo "Created question_set_reference\n";

// 8. Rebuild caches
rebuild_course_cache($courseid, true);
purge_all_caches();

echo "\nQuiz created successfully!\n";
```

### Key Points for Quiz Creation

1. **Use `quiz_add_quiz_question()`** - This is the official Moodle API
2. **Set version field** - Always ensure `question_references.version = 1`
3. **Create question_set_reference** - Links the quiz to the question bank context
4. **Use question_bank_entry IDs** - Not question IDs, not slot IDs
5. **Clear caches** - Always `purge_all_caches()` after structural changes

---

## Cognitive Science Principles

### Spacing and Retrieval Practice

**Principle**: Repeated retrieval over spaced intervals strengthens memory more than massed practice.

**Implementation in Moodle**:
- Allow unlimited quiz attempts (`$quiz->attempts = 0`)
- Enable "Each attempt builds on the last" (`$quiz->attemptonlast = 1`)
- Use adaptive question behavior (`$quiz->preferredbehaviour = 'adaptive'`)

```php
// Quiz settings for optimal retrieval practice
$quiz->attempts = 0; // Unlimited attempts
$quiz->attemptonlast = 0; // Each attempt independent
$quiz->grademethod = 1; // Highest grade (encourages retaking)
```

### Interleaving

**Principle**: Mixing different types of problems improves learning compared to blocked practice.

**Implementation**:
- Don't group all questions by type
- Mix factual recall, application, and analysis questions
- Use `$quiz->shufflequestions = 1` for different order each attempt

```php
// Quiz structure example
$questions = [
    71, // Factual recall
    85, // Application
    72, // Factual recall
    92, // Analysis
    73, // Factual recall
    // etc - mixed types
];
```

### Feedback Timing

**Principle**: Immediate feedback for factual questions, delayed feedback for complex problems.

**Implementation via Review Options**:

```php
// Feedback settings (bit flags)
// During attempt: 0x10000 (65536)
// Immediately after: 0x1000 (4096)
// Later while open: 0x100 (256)
// After close: 0x10 (16)

// Immediate feedback (sum = 69904)
$quiz->reviewattempt = 0x10000 + 0x1000 + 0x100 + 0x10; // 69904
$quiz->reviewcorrectness = 0x1000 + 0x100 + 0x10; // 4368
$quiz->reviewmarks = 0x1000 + 0x100 + 0x10; // 4368
$quiz->reviewspecificfeedback = 0x1000 + 0x100 + 0x10; // 4368
$quiz->reviewgeneralfeedback = 0x1000 + 0x100 + 0x10; // 4368
$quiz->reviewrightanswer = 0x1000 + 0x100 + 0x10; // 4368
```

### Desirable Difficulties

**Principle**: Some difficulty during learning enhances long-term retention.

**Implementation**:
- Use free navigation (`$quiz->navmethod = 'free'`) - students choose question order
- Shuffle answers (`$quiz->shuffleanswers = 1`)
- Don't show correct answers during attempt (only after)

```php
$quiz->navmethod = 'free'; // Non-sequential navigation
$quiz->shuffleanswers = 1; // Randomize answer order
$quiz->reviewrightanswer = 4368; // Show answers after, not during
```

### Testing Effect

**Principle**: Testing enhances learning more than restudying.

**Implementation**:
- Use quizzes as learning tools, not just assessment
- Low/no penalty for retaking (`$quiz->grademethod = 1` - keep highest)
- Include practice quizzes that don't count toward grade

```php
// Practice quiz settings
$quiz->attempts = 0; // Unlimited
$quiz->grade = 0; // Doesn't contribute to course grade
$quiz->grademethod = 1; // Keep highest
```

### Cognitive Load Management

**Principle**: Limit extraneous cognitive load to maximize learning.

**Implementation**:
- One question per page (`$quiz->questionsperpage = 1`)
- Clear, concise question text
- Minimize distracting UI elements (`$quiz->showblocks = 0`)

```php
$quiz->questionsperpage = 1; // Reduces cognitive load
$quiz->showblocks = 0; // Minimize distractions
$quiz->showuserpicture = 0; // Remove unnecessary elements
```

### Question Design Guidelines

#### 1. Multiple Choice (Metacognition)
```xml
<question type="multichoice">
  <name><text>Conceptual Understanding</text></name>
  <questiontext>
    <text>Which principle BEST explains why spaced practice is more effective than massed practice?</text>
  </questiontext>
  <answer fraction="100">
    <text>Spacing allows time for memory consolidation</text>
    <feedback><text>Correct! Consolidation requires time.</text></feedback>
  </answer>
  <answer fraction="0">
    <text>Spacing means less total study time</text>
    <feedback><text>Actually, spacing often requires similar total time.</text></feedback>
  </answer>
</question>
```

**Why**: Forces students to think about WHY, not just WHAT.

#### 2. Short Answer (Retrieval Practice)
```xml
<question type="shortanswer">
  <name><text>Recall Practice</text></name>
  <questiontext>
    <text>What is the term for the cognitive science principle that testing enhances learning more than restudying?</text>
  </questiontext>
  <answer fraction="100">
    <text>testing effect</text>
  </answer>
  <answer fraction="100">
    <text>test effect</text>
  </answer>
</question>
```

**Why**: Retrieval is more effective than recognition.

#### 3. True/False (Correct Misconceptions)
```xml
<question type="truefalse">
  <name><text>Common Misconception</text></name>
  <questiontext>
    <text>True or False: People learn best when taught in their preferred "learning style" (visual, auditory, kinesthetic).</text>
  </questiontext>
  <answer fraction="0">
    <text>True</text>
    <feedback><text>This is a myth! Research shows learning styles don't improve outcomes. The nature of the content matters more than the preferred modality.</text></feedback>
  </answer>
  <answer fraction="100">
    <text>False</text>
    <feedback><text>Correct! Learning styles theory is not supported by evidence. What matters is matching the instruction method to the content, not the learner's preference.</text></feedback>
  </answer>
</question>
```

**Why**: Directly addresses and corrects misconceptions with explanation.

---

## Common Pitfalls

### ❌ Pitfall 1: Manual Database Insertion for Quizzes

**Problem**: Directly inserting into `quiz_slots` and `question_references` causes the 's114' error.

**Why It Fails**: Moodle's quiz structure uses complex internal state that isn't fully represented in the database.

**Solution**: Use `quiz_add_quiz_question()` API.

### ❌ Pitfall 2: Missing Version Field

**Problem**: `question_references.version` is NULL or empty.

**Symptom**: Questions don't load in quiz.

**Solution**:
```php
$DB->set_field('question_references', 'version', 1, ['id' => $ref->id]);
```

### ❌ Pitfall 3: Missing Type-Specific Options

**Problem**: Question imports but doesn't display correctly.

**Solution**: Always create entries in type-specific tables:
- `qtype_truefalse`
- `qtype_shortanswer_options`
- `qtype_multichoice_options`
- etc.

### ❌ Pitfall 4: Using Question IDs Instead of Entry IDs

**Problem**: `quiz_add_quiz_question()` expects question_bank_entry IDs, not question IDs.

**Solution**:
```php
// WRONG
quiz_add_quiz_question($questionid, $quiz, 0, 1);

// CORRECT
quiz_add_quiz_question($question_bank_entry_id, $quiz, 0, 1);
```

### ❌ Pitfall 5: Forgetting question_set_references

**Problem**: Quiz appears broken or questions don't load.

**Solution**: Always create a `question_set_reference` record for each quiz.

### ❌ Pitfall 6: Not Clearing Caches

**Problem**: Changes don't appear immediately.

**Solution**: Always call `purge_all_caches()` after structural changes.

---

## Troubleshooting Guide

### Error: "Can't find data record in database" with slot ID

**Symptom**: Error shows `WHERE q.id = :id [array('id' => 's114')]`

**Diagnosis**: Quiz slots were created manually instead of via API.

**Fix**:
```php
// Delete and recreate slots using API
$slots = $DB->get_records('quiz_slots', ['quizid' => $quizid]);
foreach ($slots as $slot) {
    $DB->delete_records('question_references', [
        'component' => 'mod_quiz',
        'questionarea' => 'slot',
        'itemid' => $slot->id
    ]);
    $DB->delete_records('quiz_slots', ['id' => $slot->id]);
}

// Add questions correctly
foreach ($question_entries as $entryid) {
    quiz_add_quiz_question($entryid, $quiz, 0, 1);
}

// Fix versions
$refs = $DB->get_records_sql("
    SELECT qr.* FROM {question_references} qr
    JOIN {quiz_slots} qs ON qs.id = qr.itemid
    WHERE qs.quizid = ? AND (qr.version IS NULL OR qr.version = 0)
", [$quizid]);
foreach ($refs as $ref) {
    $DB->set_field('question_references', 'version', 1, ['id' => $ref->id]);
}

purge_all_caches();
```

### Error: Question appears blank in quiz

**Diagnosis**: Missing type-specific options.

**Fix**:
```php
$question = $DB->get_record('question', ['id' => $questionid]);

if ($question->qtype == 'truefalse') {
    $options = $DB->get_record('qtype_truefalse', ['questionid' => $questionid]);
    if (!$options) {
        // Create options (see Question Bank Management section)
    }
}
// Repeat for other question types
```

### Error: Questions in wrong order

**Diagnosis**: Quiz slots have incorrect sequence numbers.

**Fix**:
```php
$slots = $DB->get_records('quiz_slots', ['quizid' => $quizid], 'slot ASC');
$slotnum = 1;
foreach ($slots as $slot) {
    $slot->slot = $slotnum;
    $slot->page = $slotnum; // One question per page
    $DB->update_record('quiz_slots', $slot);
    $slotnum++;
}
purge_all_caches();
```

### Diagnostic Script

```php
<?php
define('CLI_SCRIPT', true);
require_once('/var/www/html/config.php');

$quizid = 10; // Change as needed

echo "=== QUIZ DIAGNOSTIC ===\n\n";

// Check quiz
$quiz = $DB->get_record('quiz', ['id' => $quizid]);
echo "Quiz: {$quiz->name}\n";
echo "Sum grades: {$quiz->sumgrades}\n\n";

// Check slots
echo "=== SLOTS ===\n";
$slots = $DB->get_records('quiz_slots', ['quizid' => $quizid], 'slot ASC');
echo count($slots) . " slots found\n\n";

// Check slot -> question mapping
echo "=== SLOT TO QUESTION MAPPING ===\n";
$sql = "SELECT
    qs.id as slotid,
    qs.slot,
    qr.questionbankentryid,
    qr.version,
    qv.questionid,
    q.name as qname,
    q.qtype
FROM {quiz_slots} qs
LEFT JOIN {question_references} qr
    ON qr.itemid = qs.id
    AND qr.questionarea = 'slot'
    AND qr.component = 'mod_quiz'
LEFT JOIN {question_versions} qv
    ON qv.questionbankentryid = qr.questionbankentryid
    AND qv.version = qr.version
LEFT JOIN {question} q ON q.id = qv.questionid
WHERE qs.quizid = ?
ORDER BY qs.slot";

$results = $DB->get_records_sql($sql, [$quizid]);
foreach ($results as $r) {
    if ($r->questionid) {
        echo "Slot {$r->slot}: Q{$r->questionid} ({$r->qtype}) - {$r->qname}\n";
    } else {
        echo "Slot {$r->slot}: ⚠️ NO QUESTION MAPPED\n";
    }
}

// Check question_set_reference
echo "\n=== QUESTION SET REFERENCE ===\n";
$setref = $DB->get_record('question_set_references', [
    'component' => 'mod_quiz',
    'questionarea' => 'slot',
    'itemid' => $quizid
]);
if ($setref) {
    echo "✓ Found (ID: {$setref->id})\n";
} else {
    echo "⚠️ MISSING - This may cause issues!\n";
}

echo "\nDone.\n";
```

---

## Complete Example Scripts

### 1. Import Questions and Create Quiz (Full Workflow)

```php
<?php
/**
 * Complete workflow: Import questions from XML and create a quiz
 *
 * Usage: ddev exec php create_course_with_quiz.php
 */

define('CLI_SCRIPT', true);
require_once('/var/www/html/config.php');
require_once($CFG->dirroot . '/mod/quiz/lib.php');
require_once($CFG->dirroot . '/mod/quiz/locallib.php');
require_once($CFG->dirroot . '/course/lib.php');

// Configuration
$courseid = 8;
$quiz_title = 'My Quiz';
$questions_xml_file = '/path/to/questions.xml';
$category_name = 'Imported Questions';

echo "=== MOODLE QUIZ CREATION WORKFLOW ===\n\n";

// Step 1: Create/get question category
echo "Step 1: Setting up question category...\n";
$coursecontext = context_course::instance($courseid);

$category = $DB->get_record('question_categories', [
    'name' => $category_name,
    'contextid' => $coursecontext->id
]);

if (!$category) {
    $category = new stdClass();
    $category->name = $category_name;
    $category->contextid = $coursecontext->id;
    $category->info = 'Automatically imported questions';
    $category->infoformat = FORMAT_HTML;
    $category->stamp = make_unique_id_code();
    $category->parent = 0;
    $category->sortorder = 999;
    $categoryid = $DB->insert_record('question_categories', $category);
    echo "  Created category ID: {$categoryid}\n";
} else {
    $categoryid = $category->id;
    echo "  Using existing category ID: {$categoryid}\n";
}

// Step 2: Import questions
echo "\nStep 2: Importing questions from XML...\n";
$xml = simplexml_load_file($questions_xml_file);
$imported_entries = [];

foreach ($xml->question as $qxml) {
    $qtype = (string)$qxml['type'];
    $qname = (string)$qxml->name->text;

    // Create question bank entry
    $entry = new stdClass();
    $entry->questioncategoryid = $categoryid;
    $entry->idnumber = null;
    $entry->ownerid = 2;
    $entryid = $DB->insert_record('question_bank_entries', $entry);

    // Create question
    $question = new stdClass();
    $question->category = $categoryid;
    $question->parent = 0;
    $question->name = $qname;
    $question->questiontext = (string)$qxml->questiontext->text;
    $question->questiontextformat = FORMAT_HTML;
    $question->generalfeedback = '';
    $question->generalfeedbackformat = FORMAT_HTML;
    $question->defaultmark = 1.0;
    $question->penalty = 0.3333333;
    $question->qtype = $qtype;
    $question->length = 1;
    $question->stamp = make_unique_id_code();
    $question->version = make_unique_id_code();
    $question->hidden = 0;
    $question->timecreated = time();
    $question->timemodified = time();
    $question->createdby = 2;
    $question->modifiedby = 2;

    $questionid = $DB->insert_record('question', $question);

    // Create version
    $version = new stdClass();
    $version->questionbankentryid = $entryid;
    $version->version = 1;
    $version->questionid = $questionid;
    $version->status = 'ready';
    $DB->insert_record('question_versions', $version);

    // Add answers
    foreach ($qxml->answer as $axml) {
        $answer = new stdClass();
        $answer->question = $questionid;
        $answer->answer = (string)$axml->text;
        $answer->answerformat = FORMAT_HTML;
        $answer->fraction = (float)$axml['fraction'] / 100;
        $answer->feedback = (string)$axml->feedback->text;
        $answer->feedbackformat = FORMAT_HTML;
        $DB->insert_record('question_answers', $answer);
    }

    // Type-specific options
    if ($qtype == 'truefalse') {
        $answers = $DB->get_records('question_answers',
            ['question' => $questionid], 'fraction DESC');
        $trueid = $falseid = 0;
        foreach ($answers as $ans) {
            if ($ans->fraction > 0) $trueid = $ans->id;
            else $falseid = $ans->id;
        }
        $tf = new stdClass();
        $tf->question = $questionid;
        $tf->trueanswer = $trueid;
        $tf->falseanswer = $falseid;
        $tf->showstandardinstruction = 1;
        $DB->insert_record('question_truefalse', $tf);
    } elseif ($qtype == 'shortanswer') {
        $sa = new stdClass();
        $sa->questionid = $questionid;
        $sa->usecase = 0;
        $DB->insert_record('qtype_shortanswer_options', $sa);
    } elseif ($qtype == 'multichoice') {
        $mc = new stdClass();
        $mc->questionid = $questionid;
        $mc->single = 1;
        $mc->shuffleanswers = 1;
        $mc->answernumbering = 'abc';
        $mc->correctfeedback = 'Correct!';
        $mc->correctfeedbackformat = FORMAT_HTML;
        $mc->partiallycorrectfeedback = 'Partially correct.';
        $mc->partiallycorrectfeedbackformat = FORMAT_HTML;
        $mc->incorrectfeedback = 'Incorrect.';
        $mc->incorrectfeedbackformat = FORMAT_HTML;
        $mc->shownumcorrect = 1;
        $DB->insert_record('qtype_multichoice_options', $mc);
    }

    $imported_entries[] = $entryid;
    echo "  Imported: {$qname} (Entry: {$entryid}, Question: {$questionid})\n";
}

echo "  Total imported: " . count($imported_entries) . " questions\n";

// Step 3: Create quiz
echo "\nStep 3: Creating quiz...\n";

$quiz = new stdClass();
$quiz->course = $courseid;
$quiz->name = $quiz_title;
$quiz->intro = '<p>Quiz created automatically</p>';
$quiz->introformat = FORMAT_HTML;
$quiz->timeopen = 0;
$quiz->timeclose = 0;
$quiz->timelimit = 0;
$quiz->overduehandling = 'autosubmit';
$quiz->graceperiod = 0;
$quiz->preferredbehaviour = 'deferredfeedback';
$quiz->canredoquestions = 0;
$quiz->attempts = 0; // Unlimited for practice
$quiz->attemptonlast = 0;
$quiz->grademethod = 1; // Highest grade
$quiz->decimalpoints = 2;
$quiz->questiondecimalpoints = -1;
$quiz->reviewattempt = 69904;
$quiz->reviewcorrectness = 4368;
$quiz->reviewmaxmarks = 0;
$quiz->reviewmarks = 4368;
$quiz->reviewspecificfeedback = 4368;
$quiz->reviewgeneralfeedback = 4368;
$quiz->reviewrightanswer = 4368;
$quiz->reviewoverallfeedback = 4368;
$quiz->questionsperpage = 1;
$quiz->navmethod = 'free';
$quiz->shuffleanswers = 1;
$quiz->sumgrades = count($imported_entries);
$quiz->grade = 100;
$quiz->timecreated = time();
$quiz->timemodified = time();
$quiz->password = '';
$quiz->subnet = '';
$quiz->browsersecurity = '-';
$quiz->delay1 = 0;
$quiz->delay2 = 0;
$quiz->showuserpicture = 0;
$quiz->showblocks = 0;
$quiz->completionattemptsexhausted = 0;
$quiz->completionminattempts = 0;
$quiz->allowofflineattempts = 0;

$quizid = $DB->insert_record('quiz', $quiz);
$quiz->id = $quizid;
echo "  Created quiz ID: {$quizid}\n";

// Create course module
$cm = new stdClass();
$cm->course = $courseid;
$cm->module = $DB->get_field('modules', 'id', ['name' => 'quiz']);
$cm->instance = $quizid;
$cm->section = 1;
$cm->visible = 1;
$cm->visibleoncoursepage = 1;
$cm->visibleold = 1;
$cm->groupmode = 0;
$cm->groupingid = 0;
$cm->completion = 0;
$cm->completionview = 0;
$cm->completionexpected = 0;
$cm->showdescription = 0;
$cm->availability = null;
$cm->deletioninprogress = 0;

$cmid = add_course_module($cm);
course_add_cm_to_section($courseid, $cmid, $cm->section);
echo "  Created course module ID: {$cmid}\n";

// Create grade item
quiz_grade_item_update($quiz);

// Create quiz section
$section = new stdClass();
$section->quizid = $quizid;
$section->firstslot = 1;
$section->heading = '';
$section->shufflequestions = 0;
$DB->insert_record('quiz_sections', $section);

// Step 4: Add questions to quiz
echo "\nStep 4: Adding questions to quiz...\n";

foreach ($imported_entries as $entryid) {
    quiz_add_quiz_question($entryid, $quiz, 0, 1);
}
echo "  Added " . count($imported_entries) . " questions\n";

// Fix version fields
$refs = $DB->get_records_sql("
    SELECT qr.*
    FROM {question_references} qr
    JOIN {quiz_slots} qs ON qs.id = qr.itemid
    WHERE qs.quizid = ?
    AND qr.component = 'mod_quiz'
    AND qr.questionarea = 'slot'
    AND (qr.version IS NULL OR qr.version = '' OR qr.version = 0)
", [$quizid]);

foreach ($refs as $ref) {
    $DB->set_field('question_references', 'version', 1, ['id' => $ref->id]);
}
if (count($refs) > 0) {
    echo "  Fixed " . count($refs) . " version fields\n";
}

// Create question_set_reference
$setref = new stdClass();
$setref->usingcontextid = $coursecontext->id;
$setref->component = 'mod_quiz';
$setref->questionarea = 'slot';
$setref->itemid = $quizid;
$setref->questionscontextid = $coursecontext->id;
$DB->insert_record('question_set_references', $setref);

// Step 5: Final cleanup
echo "\nStep 5: Rebuilding caches...\n";
rebuild_course_cache($courseid, true);
purge_all_caches();

echo "\n=== COMPLETE ===\n";
echo "Quiz '{$quiz_title}' created with " . count($imported_entries) . " questions\n";
echo "Quiz ID: {$quizid}\n";
echo "Course Module ID: {$cmid}\n";
```

---

## Summary Checklist

When creating a Moodle course with quizzes:

- [ ] Create or identify course
- [ ] Create question category in appropriate context
- [ ] Import questions with proper structure:
  - [ ] question_bank_entries
  - [ ] question_versions
  - [ ] question (actual question data)
  - [ ] question_answers
  - [ ] Type-specific options tables
- [ ] Create quiz record
- [ ] Create course module and link to quiz
- [ ] Create grade item
- [ ] Create quiz section
- [ ] **Use `quiz_add_quiz_question()` API** to add questions
- [ ] Fix version fields in question_references (set to 1)
- [ ] Create question_set_reference
- [ ] Rebuild course cache
- [ ] Purge all caches
- [ ] Test quiz functionality

---

## Additional Resources

### Moodle Documentation
- [Quiz module](https://docs.moodle.org/en/Quiz)
- [Question bank](https://docs.moodle.org/en/Question_bank)
- [Question types](https://docs.moodle.org/en/Question_types)

### Cognitive Science References
- *Make It Stick* by Brown, Roediger, and McDaniel
- *How Learning Works* by Ambrose et al.
- *Why Don't Students Like School?* by Daniel Willingham

### Key Functions to Remember
- `quiz_add_quiz_question($entryid, $quiz, $page, $maxmark)` - Add question to quiz
- `quiz_grade_item_update($quiz)` - Create/update grade item
- `add_course_module($cm)` - Create course module
- `course_add_cm_to_section($courseid, $cmid, $section)` - Add to section
- `rebuild_course_cache($courseid, $clearonly)` - Rebuild course
- `purge_all_caches()` - Clear all Moodle caches

---

**Version**: 1.0
**Last Updated**: 2025-01-13
**Moodle Version**: 4.4+
**Author**: Created from lessons learned during Rosary course import project

---

## License

This guide is provided as-is for educational purposes. Moodle is GPL licensed.
