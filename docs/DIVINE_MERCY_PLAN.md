# Divine Mercy Prayer Site - Implementation Plan

## 1. Overview

### 1.1 Project Goal
Create a Drupal 11 site for the Divine Mercy Chaplet and Novena with structured content, user contributions, and multilingual support.

### 1.2 Source
`/home/greg/nwp/dma/source/Chaplet.htm` (341KB static HTML from Blogger)

### 1.3 Key Requirements
1. Structured content types for prayers and novena days
2. Private user suggestion system (visible only to admins)
3. User-contributed prayers and translations
4. Native Drupal interactive features
5. Full i18n support for multiple languages

---

## 2. Content Architecture

### 2.1 Content Type: Prayer (`prayer`)

| # | Field | Type | Purpose |
|---|-------|------|---------|
| 2.1.1 | title | String | Prayer name |
| 2.1.2 | body | Text (long) | Prayer text |
| 2.1.3 | field_prayer_type | Taxonomy ref | standard, chaplet, novena, closing |
| 2.1.4 | field_prayer_category | Taxonomy ref | leader, response, full |
| 2.1.5 | field_prayer_order | Integer | Display order |
| 2.1.6 | field_latin_text | Text (long) | Latin version |
| 2.1.7 | field_has_variant | Boolean | Has Flame of Love variant |
| 2.1.8 | field_variant_text | Text (long) | Variant prayer text |

### 2.2 Content Type: Novena Day (`novena_day`)

| # | Field | Type | Purpose |
|---|-------|------|---------|
| 2.2.1 | title | String | Day title |
| 2.2.2 | field_day_number | Integer | 1-9 |
| 2.2.3 | field_theme | String | Day theme |
| 2.2.4 | field_intention | Text (long) | Jesus's words |
| 2.2.5 | field_prayer | Text (long) | Day's prayer |
| 2.2.6 | field_weekday | Integer | Mapped weekday (Fri=1, Sat=2...) |

### 2.3 Content Type: Prayer Collection (`prayer_collection`)

| # | Field | Type | Purpose |
|---|-------|------|---------|
| 2.3.1 | title | String | Collection name |
| 2.3.2 | body | Text (long) | Description |
| 2.3.3 | field_prayers | Entity ref (multiple) | Ordered prayer references |

### 2.4 Taxonomies

| # | Vocabulary | Terms |
|---|------------|-------|
| 2.4.1 | prayer_type | standard, chaplet_specific, novena, opening, closing |
| 2.4.2 | prayer_category | leader, response, full, reflection |
| 2.4.3 | reflection_type | events, suffering, scriptural, flame_of_love |

---

## 3. Custom Module Structure

### 3.1 Module Location
`web/modules/custom/divine_mercy/`

### 3.2 Directory Structure

```
3.2.1  divine_mercy/
3.2.2  ├── divine_mercy.info.yml
3.2.3  ├── divine_mercy.module
3.2.4  ├── divine_mercy.install
3.2.5  ├── divine_mercy.libraries.yml
3.2.6  ├── divine_mercy.routing.yml
3.2.7  ├── divine_mercy.permissions.yml
3.2.8  ├── config/
3.2.9  │   └── install/
3.2.10 │       ├── node.type.prayer.yml
3.2.11 │       ├── node.type.novena_day.yml
3.2.12 │       ├── node.type.prayer_collection.yml
3.2.13 │       ├── taxonomy.vocabulary.prayer_type.yml
3.2.14 │       ├── user.role.divine_mercy_contributor.yml
3.2.15 │       ├── user.role.divine_mercy_editor.yml
3.2.16 │       └── (field configs...)
3.2.17 ├── src/
3.2.18 │   ├── Entity/
3.2.19 │   │   └── PrayerSuggestion.php
3.2.20 │   ├── Controller/
3.2.21 │   │   ├── ChapletController.php
3.2.22 │   │   └── NovenaController.php
3.2.23 │   ├── Form/
3.2.24 │   │   ├── PrayerSuggestionForm.php
3.2.25 │   │   └── SuggestionReviewForm.php
3.2.26 │   ├── Plugin/Block/
3.2.27 │   │   ├── FontSizeControlBlock.php
3.2.28 │   │   ├── NovenaNavigationBlock.php
3.2.29 │   │   └── EucharistAdorationBlock.php
3.2.30 │   └── Service/
3.2.31 │       ├── PrayerService.php
3.2.32 │       └── NovenaService.php
3.2.33 ├── templates/
3.2.34 │   ├── divine-mercy-chaplet.html.twig
3.2.35 │   ├── divine-mercy-prayer.html.twig
3.2.36 │   └── divine-mercy-novena-day.html.twig
3.2.37 ├── css/
3.2.38 │   └── divine-mercy.css
3.2.39 └── js/
3.2.40     ├── font-size-control.js
3.2.41     ├── novena-navigation.js
3.2.42     └── expandable-sections.js
```

---

## 4. Private Suggestion System

### 4.1 Custom Entity: PrayerSuggestion

| # | Field | Type | Purpose |
|---|-------|------|---------|
| 4.1.1 | id | Integer (auto) | Unique ID |
| 4.1.2 | target_entity_type | String | 'node' or 'taxonomy_term' |
| 4.1.3 | target_entity_id | Integer | Content being commented on |
| 4.1.4 | suggestion_type | String | correction, addition, translation, variation |
| 4.1.5 | suggestion_text | Text (long) | The user's suggestion |
| 4.1.6 | proposed_text | Text (long) | Proposed new/modified content |
| 4.1.7 | language | Language ref | For translation suggestions |
| 4.1.8 | user_id | Entity ref (user) | Submitting user |
| 4.1.9 | status | String | pending, reviewed, accepted, rejected |
| 4.1.10 | admin_notes | Text (long) | Admin response (private) |
| 4.1.11 | created | Timestamp | Creation date |

### 4.2 User Roles

| # | Role | Permissions |
|---|------|-------------|
| 4.2.1 | Authenticated | View prayers, submit suggestions |
| 4.2.2 | Contributor | Submit new prayers, translations |
| 4.2.3 | Editor | Review suggestions, edit content |
| 4.2.4 | Admin | Full access |

### 4.3 Custom Permissions

| # | Permission | Description |
|---|------------|-------------|
| 4.3.1 | submit prayer suggestions | Submit private suggestions on prayer content |
| 4.3.2 | submit prayer translations | Submit new language translations |
| 4.3.3 | submit new prayers | Suggest new prayers for inclusion |
| 4.3.4 | review prayer suggestions | View and moderate suggestions |
| 4.3.5 | administer divine mercy | Full administrative access |

---

## 5. Interactive Features (Native Drupal)

### 5.1 Font Size Control

| # | Component | Description |
|---|-----------|-------------|
| 5.1.1 | Block | FontSizeControlBlock.php with slider (50-200%) |
| 5.1.2 | JavaScript | font-size-control.js as Drupal behavior |
| 5.1.3 | CSS | Uses custom property `--prayer-font-size` |
| 5.1.4 | Storage | localStorage for user preference |

### 5.2 Novena Day Navigation

| # | Component | Description |
|---|-----------|-------------|
| 5.2.1 | Service | NovenaService.php calculates current day |
| 5.2.2 | Mapping | Friday=Day 1, Saturday=Day 2, etc. |
| 5.2.3 | Block | NovenaNavigationBlock.php with day buttons |
| 5.2.4 | Feature | On Fri/Sat shows both ending + starting novena days |

### 5.3 Expandable Sections

| # | Component | Description |
|---|-----------|-------------|
| 5.3.1 | Trigger | Blue ellipsis (...) click to expand |
| 5.3.2 | JavaScript | expandable-sections.js as Drupal behavior |
| 5.3.3 | Accessibility | aria-expanded attributes |

### 5.4 Eucharist Adoration Block

| # | Component | Description |
|---|-----------|-------------|
| 5.4.1 | Block | EucharistAdorationBlock.php |
| 5.4.2 | Feature | Configurable YouTube embed with chapel selector |
| 5.4.3 | Position | Fixed position option (like original) |

---

## 6. Internationalization (i18n)

### 6.1 Required Modules

| # | Module | Purpose |
|---|--------|---------|
| 6.1.1 | language | Language management |
| 6.1.2 | locale | Interface translation |
| 6.1.3 | content_translation | Content translation |
| 6.1.4 | config_translation | Configuration translation |

### 6.2 Translatable Content
All content types configured with `translatable: true`

### 6.3 Translation Workflow

| # | Step | Description |
|---|------|-------------|
| 6.3.1 | Submit | User submits translation via PrayerSuggestion (type: translation) |
| 6.3.2 | Review | Admin reviews in suggestion queue |
| 6.3.3 | Approve | Admin creates official translation |

### 6.4 Available Languages (30+ confirmed)

#### 6.4.1 Priority Languages (Phase 1)

| # | Language | Code | Notes |
|---|----------|------|-------|
| 6.4.1.1 | English | en | Default |
| 6.4.1.2 | Spanish | es | Large Catholic population |
| 6.4.1.3 | Polish | pl | Original language (St. Faustina) |
| 6.4.1.4 | Portuguese | pt | Brazil, Portugal |
| 6.4.1.5 | French | fr | Global Francophone |
| 6.4.1.6 | Latin | la | Traditional prayers |

#### 6.4.2 European Languages (Phase 2)

| # | Language | Code | Notes |
|---|----------|------|-------|
| 6.4.2.1 | Italian | it | Vatican publication |
| 6.4.2.2 | German | de | Available |
| 6.4.2.3 | Dutch | nl | Available |
| 6.4.2.4 | Russian | ru | Available |
| 6.4.2.5 | Czech | cs | Available |
| 6.4.2.6 | Slovak | sk | Available |
| 6.4.2.7 | Greek | el | Available |
| 6.4.2.8 | Romanian | ro | Available |
| 6.4.2.9 | Hungarian | hu | Available |

#### 6.4.3 Asian Languages (Phase 3)

| # | Language | Code | Notes |
|---|----------|------|-------|
| 6.4.3.1 | Tagalog | tl | Philippines - large Catholic population |
| 6.4.3.2 | Vietnamese | vi | Growing Catholic community |
| 6.4.3.3 | Korean | ko | Available |
| 6.4.3.4 | Chinese (Traditional) | zh-Hant | Taiwan, Hong Kong |
| 6.4.3.5 | Chinese (Simplified) | zh-Hans | Mainland China |
| 6.4.3.6 | Japanese | ja | Available |
| 6.4.3.7 | Indonesian | id | Available |
| 6.4.3.8 | Hindi | hi | India |
| 6.4.3.9 | Malayalam | ml | Kerala, India |
| 6.4.3.10 | Tamil | ta | Tamil Nadu, India |
| 6.4.3.11 | Kannada | kn | Karnataka, India |

#### 6.4.4 African Languages (Phase 4)

| # | Language | Code | Notes |
|---|----------|------|-------|
| 6.4.4.1 | Kiswahili (Swahili) | sw | East Africa |
| 6.4.4.2 | Amharic | am | Ethiopia |
| 6.4.4.3 | Tigrinya | ti | Eritrea/Ethiopia |
| 6.4.4.4 | Somali | so | Somalia |

#### 6.4.5 Other Languages (Future)

| # | Language | Code | Notes |
|---|----------|------|-------|
| 6.4.5.1 | Arabic | ar | Middle East |
| 6.4.5.2 | Chamorro | ch | Guam/Mariana Islands |

### 6.5 Language Implementation Strategy

| # | Phase | Languages | Priority |
|---|-------|-----------|----------|
| 6.5.1 | Phase 1 | en, es, pl, pt, fr, la | High - launch languages |
| 6.5.2 | Phase 2 | it, de, nl, ru, cs, sk, el, ro, hu | Medium - European expansion |
| 6.5.3 | Phase 3 | tl, vi, ko, zh, ja, id, hi, ml, ta, kn | Medium - Asian expansion |
| 6.5.4 | Phase 4 | sw, am, ti, so, ar, ch | Lower - community-driven |

---

## 7. Content Migration

### 7.1 Prayers to Extract

| # | Prayer | Notes |
|---|--------|-------|
| 7.1.1 | Sign of the Cross | Opening |
| 7.1.2 | St. Faustina's Opening Prayer | For Sinners |
| 7.1.3 | "You expired, Jesus..." | Opening sequence |
| 7.1.4 | "O Blood and Water..." | 3x repetition |
| 7.1.5 | Our Father | Leader/response split |
| 7.1.6 | Hail Mary | Leader/response + Flame of Love variant |
| 7.1.7 | Apostles' Creed | Leader/response |
| 7.1.8 | "Eternal Father, I offer you..." | Large bead prayer |
| 7.1.9 | "For the sake of His Sorrowful Passion..." | Small bead x10 |
| 7.1.10 | "Holy God, Holy Mighty One..." | Closing 3x |
| 7.1.11 | Final closing prayer | End |

### 7.2 Novena Days

| # | Day | Theme |
|---|-----|-------|
| 7.2.1 | Day 1 | All Mankind, Especially Sinners |
| 7.2.2 | Day 2 | Priests and Religious |
| 7.2.3 | Day 3 | Devout and Faithful Souls |
| 7.2.4 | Day 4 | Those Who Do Not Believe |
| 7.2.5 | Day 5 | Separated Brethren |
| 7.2.6 | Day 6 | Meek and Humble Souls |
| 7.2.7 | Day 7 | Those Who Venerate Divine Mercy |
| 7.2.8 | Day 8 | Souls in Purgatory |
| 7.2.9 | Day 9 | Lukewarm Souls |

### 7.3 Migration Approach

| # | Option | Description |
|---|--------|-------------|
| 7.3.1 | migrate_plus | Use embedded_data source with YAML |
| 7.3.2 | Manual entry | Admin interface with pre-populated templates |

---

## 8. Implementation Steps

### 8.1 Phase 1: Foundation

| # | Task |
|---|------|
| 8.1.1 | Create site with `./install.sh d dma_site` |
| 8.1.2 | Create divine_mercy module skeleton |
| 8.1.3 | Define content types in config/install |
| 8.1.4 | Define taxonomies in config/install |
| 8.1.5 | Create user roles and permissions |

### 8.2 Phase 2: Suggestion System

| # | Task |
|---|------|
| 8.2.1 | Implement PrayerSuggestion entity |
| 8.2.2 | Create PrayerSuggestionForm |
| 8.2.3 | Create SuggestionReviewForm |
| 8.2.4 | Build Views for admin suggestion queue |

### 8.3 Phase 3: Display Layer

| # | Task |
|---|------|
| 8.3.1 | Create ChapletController |
| 8.3.2 | Create NovenaController |
| 8.3.3 | Build divine-mercy-chaplet.html.twig |
| 8.3.4 | Build divine-mercy-prayer.html.twig |
| 8.3.5 | Build divine-mercy-novena-day.html.twig |

### 8.4 Phase 4: Interactive Blocks

| # | Task |
|---|------|
| 8.4.1 | Create FontSizeControlBlock |
| 8.4.2 | Create NovenaNavigationBlock |
| 8.4.3 | Create EucharistAdorationBlock |
| 8.4.4 | Implement font-size-control.js |
| 8.4.5 | Implement novena-navigation.js |
| 8.4.6 | Implement expandable-sections.js |
| 8.4.7 | Create divine-mercy.css |

### 8.5 Phase 5: Content

| # | Task |
|---|------|
| 8.5.1 | Create migration YAML or entry forms |
| 8.5.2 | Migrate/enter prayers from HTML |
| 8.5.3 | Enter novena day content |
| 8.5.4 | Create prayer collections |

### 8.6 Phase 6: i18n (Phase 1 Languages)

| # | Task |
|---|------|
| 8.6.1 | Enable translation modules (language, locale, content_translation, config_translation) |
| 8.6.2 | Configure content translation for all types |
| 8.6.3 | Set up translation suggestion workflow |
| 8.6.4 | Add Spanish (es) translations |
| 8.6.5 | Add Polish (pl) translations - original language |
| 8.6.6 | Add Portuguese (pt) translations |
| 8.6.7 | Add French (fr) translations |
| 8.6.8 | Add Latin (la) translations for prayers |

### 8.7 Phase 7: i18n (European Languages - Phase 2)

| # | Task |
|---|------|
| 8.7.1 | Add Italian (it) translations |
| 8.7.2 | Add German (de) translations |
| 8.7.3 | Add remaining European languages (nl, ru, cs, sk, el, ro, hu) |

### 8.8 Phase 8: i18n (Asian & Other Languages - Phase 3-4)

| # | Task |
|---|------|
| 8.8.1 | Add Tagalog (tl) translations |
| 8.8.2 | Add Vietnamese (vi) translations |
| 8.8.3 | Add Korean (ko) translations |
| 8.8.4 | Add Chinese (zh-Hant, zh-Hans) translations |
| 8.8.5 | Add remaining Asian languages (ja, id, hi, ml, ta, kn) |
| 8.8.6 | Add African languages (sw, am, ti, so) - community-driven |
| 8.8.7 | Add Arabic (ar) and other languages as contributed |

---

## 9. Key Files to Create

| # | File Path | Purpose |
|---|-----------|---------|
| 9.1 | `divine_mercy/divine_mercy.info.yml` | Module definition |
| 9.2 | `divine_mercy/divine_mercy.module` | Hook implementations |
| 9.3 | `divine_mercy/divine_mercy.install` | Install/uninstall |
| 9.4 | `divine_mercy/divine_mercy.routing.yml` | Routes |
| 9.5 | `divine_mercy/divine_mercy.permissions.yml` | Permissions |
| 9.6 | `divine_mercy/divine_mercy.libraries.yml` | JS/CSS libraries |
| 9.7 | `divine_mercy/src/Entity/PrayerSuggestion.php` | Suggestion entity |
| 9.8 | `divine_mercy/src/Controller/ChapletController.php` | Chaplet display |
| 9.9 | `divine_mercy/src/Controller/NovenaController.php` | Novena display |
| 9.10 | `divine_mercy/src/Form/PrayerSuggestionForm.php` | Suggestion form |
| 9.11 | `divine_mercy/src/Form/SuggestionReviewForm.php` | Admin review |
| 9.12 | `divine_mercy/src/Plugin/Block/FontSizeControlBlock.php` | Font block |
| 9.13 | `divine_mercy/src/Plugin/Block/NovenaNavigationBlock.php` | Nav block |
| 9.14 | `divine_mercy/src/Plugin/Block/EucharistAdorationBlock.php` | Video block |
| 9.15 | `divine_mercy/src/Service/PrayerService.php` | Prayer logic |
| 9.16 | `divine_mercy/src/Service/NovenaService.php` | Novena logic |
| 9.17 | `divine_mercy/templates/divine-mercy-chaplet.html.twig` | Chaplet template |
| 9.18 | `divine_mercy/templates/divine-mercy-prayer.html.twig` | Prayer template |
| 9.19 | `divine_mercy/templates/divine-mercy-novena-day.html.twig` | Novena template |
| 9.20 | `divine_mercy/js/font-size-control.js` | Font behavior |
| 9.21 | `divine_mercy/js/novena-navigation.js` | Nav behavior |
| 9.22 | `divine_mercy/js/expandable-sections.js` | Expand behavior |
| 9.23 | `divine_mercy/css/divine-mercy.css` | Styles |
