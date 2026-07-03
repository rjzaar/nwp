# Stage 4 — Community seed content (groups + topics)

Produce a **seed JSON** of community groups and discussion topics for the
**{{SET_TITLE}}** community site (set slug `{{SET_SLUG}}`). The community-build
stage feeds this to `seed_social.php` to seed the Open Social / nwc community
(groups, and an opening discussion topic per group).

## Hard rule — seed THIS set's community, not Saint School's

Group names, descriptions, and topics MUST reflect **{{SET_TITLE}}** and its own
taxonomy/vocabulary (below). **NEVER reuse Saint School's Catholic-theology
group names, guilds, or topics.** Derive the community structure from this
podcast's actual themes.

## This set's vocabulary + taxonomy

```
{{VOCAB}}
```

## Required JSON shape

```json
{
  "site": {
    "name": "{{SET_TITLE}} Community",
    "registration": "admin_only"
  },
  "groups": [
    {
      "name": "<Group name — one per paradigm rail or major theme>",
      "type": "open",
      "description": "One or two sentences on what this group is for.",
      "paradigm": "<rail-slug from allowed_paradigm_elements>",
      "topics": [
        {
          "title": "<Opening discussion topic>",
          "body": "A welcoming first post that invites conversation on this theme."
        }
      ]
    }
  ]
}
```

## Constraints

- Create **one group per paradigm rail** (from `allowed_paradigm_elements`), plus
  optionally a general "Welcome / Introductions" group. Keep it small and real —
  do not pad.
- Each `groups[*].paradigm` MUST be in `allowed_paradigm_elements` (except a
  general welcome group, which may omit `paradigm`).
- 1–3 opening topics per group. Topic bodies should sound like a real
  community host, grounded in **{{SET_TITLE}}**'s subject matter.
- `registration` reflects login v1: admin-only registration (`admin_only`).

## Set context

- title: {{SET_TITLE}}
- description: {{SET_DESCRIPTION}}

## Output

Emit **only** the JSON object — no prose, no code fences.
