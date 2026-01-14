# ADR-0012: CC0 Public Domain Dedication

**Status:** Accepted
**Date:** 2026-01-14
**Decision Makers:** Rob Zaar
**Related Issues:** License choice, v0.22.0 release
**Related Commits:** ceffcda9, e17553c2
**References:** [CC0_DEDICATION.md](../CC0_DEDICATION.md), [CONTRIBUTING.md](../../CONTRIBUTING.md), [LICENSE](../../LICENSE)

## Context

> *"Freely you have received, freely give."* — Matthew 10:8

NWP needed a software license that reflected both:
1. **Technical reality** - Maximum freedom for users
2. **Spiritual foundation** - Principle of generosity and freely sharing

The project was created with AI assistance (Claude), raising questions about:
- Copyright ownership of AI-generated code
- Attribution requirements
- Commercial use restrictions
- License compliance burden

## Options Considered

### Option 1: CC0 1.0 Universal (Public Domain) - CHOSEN
- **Attribution required:** No
- **Copyleft:** No
- **Commercial use:** Yes, unrestricted
- **Warranty:** None

**Pros:**
- Maximum freedom for users
- Zero license compliance burden
- No need to track attributions
- AI-generated content clearly freed
- Aligns with Matthew 10:8 principle

**Cons:**
- No legal protection against misuse
- Can be incorporated into proprietary software
- Users not required to give back improvements

### Option 2: MIT License
- **Attribution required:** Yes
- **Copyleft:** No

**Pros:**
- Simple, well-understood
- Permissive

**Cons:**
- Requires attribution (license compliance)
- More restrictive than CC0
- Doesn't address AI-generated content clearly

### Option 3: GPL v3
- **Attribution required:** Yes
- **Copyleft:** Yes (viral)

**Pros:**
- Ensures improvements stay open
- Patent grant
- Strong copyleft

**Cons:**
- Copyleft incompatible with proprietary use
- Heavy compliance burden
- Hostile to commercial adoption
- Against "freely give" principle

### Option 4: Apache 2.0
- **Attribution required:** Yes
- **Patent grant:** Yes

**Pros:**
- Patent protection
- Commercial-friendly

**Cons:**
- Still requires attribution
- More complex than MIT
- Doesn't address AI content

## Decision

Dedicate all NWP code and documentation to the **public domain** using **CC0 1.0 Universal**.

**Full dedication:** Rob Zaar waives all copyright and related rights to the extent possible under law.

**AI-generated content:** All code created with Claude assistance is likewise dedicated to public domain.

## Rationale

### Maximum Freedom

Development tools should have **zero barriers to use**:
- No attribution tracking
- No license file maintenance
- No lawyer review needed
- Works in any jurisdiction

### Spiritual Foundation

Matthew 10:8 principle:
- NWP was created using free tools (open source, free AI)
- Therefore it should be freely given
- No restrictions on how others use it
- "Freely you have received, freely give"

### AI Collaboration Clarity

**Problem:** AI-generated code has murky copyright status
- AI doesn't hold copyright
- User owns outputs (per Anthropic ToS)
- But legal landscape is evolving

**Solution:** CC0 makes it irrelevant
- Human author dedicates all to public domain
- AI-generated portions likewise dedicated
- Clear intent: everything is free to use
- No ambiguity about AI content

### Practical Benefits

**For users:**
- Deploy commercially without fees
- Modify without releasing changes
- Incorporate into proprietary software
- No compliance overhead

**For contributors:**
- Simple: Your contribution becomes public domain
- No CLA (Contributor License Agreement) complexity
- No license debates

**For adoption:**
- Businesses can adopt immediately
- No legal review delays
- Educational use unrestricted

### Comparison

| License | Attribution | Copyleft | AI Content Clarity |
|---------|-------------|----------|-------------------|
| CC0 (chosen) | No | No | Yes (explicit dedication) |
| MIT | Yes | No | Unclear |
| Apache 2.0 | Yes | No | Unclear |
| GPL v3 | Yes | Yes | Unclear |

## Consequences

### Positive
- **Maximum adoption** - Zero legal barriers
- **Clear AI handling** - Explicit public domain dedication
- **No compliance burden** - Users don't track licenses
- **Educational value** - Students can use freely
- **Commercial friendly** - Businesses adopt faster
- **Spiritual integrity** - Aligns with "freely give"

### Negative
- **No attribution** - Users not required to credit NWP
- **Proprietary forks possible** - Someone could close-source it
- **No giveback requirement** - Improvements may not return

### Neutral
- **Third-party dependencies** - Drupal (GPL), DDEV (Apache), etc. keep their licenses
- **No warranty** - Explicitly disclaimed (standard for open source)

## Implementation Notes

### Documentation Added

1. **CC0_DEDICATION.md** - Full explanation and rationale
2. **LICENSE** - Official CC0 1.0 Universal text
3. **CONTRIBUTING.md** - Contributor agreement (must agree to CC0)
4. **example.cnwp.yml** - License metadata (informational)
5. **README.md** - License badge and link

### Contributor Agreement

By contributing to NWP, contributors agree to dedicate their contributions to public domain under CC0 1.0 Universal. This ensures the project remains freely available to everyone.

### Exceptions

**Not covered by CC0:**
- Third-party dependencies (Drupal, DDEV, etc.)
- Trademarks (if any are registered in future)
- Patents (CC0 doesn't address patents)

## Alternatives Considered

### Alternative 1: Dual License (CC0 + MIT)

Offer users choice of license.

**Rejected because:**
- Adds complexity
- CC0 already covers everything MIT does
- Confusing for users

### Alternative 2: Copyleft License (GPL/AGPL)

Force improvements to stay open.

**Rejected because:**
- Against "freely give" principle
- Harms commercial adoption
- NWP is infrastructure, not end-user product
- Users should be free to use however they want

### Alternative 3: Public Domain Dedication Without CC0

Just declare it public domain.

**Rejected because:**
- Not legally clear in all jurisdictions
- CC0 provides fallback license
- CC0 is internationally recognized
- Explicit waiver is clearer

## Migration Path

**Effective date:** January 14, 2026 (v0.22.0)

**Retroactive application:**
- All prior commits retroactively dedicated to public domain
- Rob Zaar holds all copyright to prior work
- Legal right to retroactively dedicate

**Future contributions:**
- Contributors must agree to CC0 dedication
- Stated in CONTRIBUTING.md
- PR template includes checkbox

## Review

**30-day review date:** 2026-02-14
**Review outcome:** Pending

**Success Metrics:**
- [x] All documentation updated
- [x] LICENSE file added
- [x] Contributor agreement in place
- [ ] Community feedback on license choice
- [ ] Increased adoption due to zero compliance burden

## Related Decisions

- **ADR-0005: Distributed Contribution Governance** - Contributors must agree to CC0
- **ADR-0014: Git Hooks for Documentation Enforcement** (pending) - License info in headers

## Biblical Foundation

### Matthew 10:8 Context

**Full verse:**
> "Heal the sick, raise the dead, cleanse those who have leprosy, drive out demons. Freely you have received; freely give."

**Application to NWP:**
- We received freely: Linux, Drupal, Docker, DDEV, GitLab, bash, AI assistance
- We give freely: NWP with no restrictions
- This isn't about legal strategy—it's about faithfulness to principles
- Software can be an act of generosity and service

**Other relevant passages:**
- 2 Corinthians 9:7 - "God loves a cheerful giver"
- Proverbs 11:25 - "A generous person will prosper"
- Luke 6:38 - "Give, and it will be given to you"

## Philosophical Foundation

Beyond biblical principles:

**Information wants to be free:**
- Knowledge shared grows
- Restrictions limit innovation
- Public domain maximizes benefit

**Standing on shoulders of giants:**
- All software builds on prior work
- NWP couldn't exist without open source
- Giving back is ethical obligation

**Pragmatic idealism:**
- Idealistic: Public domain is right
- Pragmatic: It increases adoption
- Both goals aligned

## FAQs

**Q: Can someone take NWP and sell it?**
A: Yes. That's their freedom. But the open version remains available.

**Q: What if they don't give improvements back?**
A: That's their choice. We hope they will, but won't force it.

**Q: Why not require attribution?**
A: Attribution is nice but creates compliance burden. Freedom > credit.

**Q: What about patents?**
A: CC0 doesn't grant patent rights. But NWP doesn't involve patents.

**Q: Can I relicense NWP code under MIT/GPL?**
A: Yes. Public domain means you can license it however you want.

**Q: Do I have to use CC0 for my NWP-based project?**
A: No. Use any license you want. That's the point of public domain.
