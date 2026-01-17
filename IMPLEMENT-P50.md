# P50 Implementation Task (Self-Managing)

**Run with:** `implement /home/rob/nwp/IMPLEMENT-P50.md`
**Repeat until:** All tasks marked `[x]` and STATUS says COMPLETE

---

## INSTRUCTIONS FOR CLAUDE

### Session Rules

1. **Read CLAUDE.md first** - Contains project standing orders
2. **One chunk per session** - Complete 1-3 tasks, commit, then exit
3. **Update this file** - Mark completed tasks `[x]`, update STATUS
4. **Commit progress** - After completing tasks, commit with descriptive message
5. **Exit cleanly** - Say "Session complete. Run again to continue." and stop

### Safety Rules

- **Check file sizes** before reading: `ls -lh <file>`
- **Use head/tail** for large outputs (never read >1MB files fully)
- **No background tasks** for tests - run synchronously with timeouts
- **Kill runaway processes** immediately if output grows large

### When to Exit

Exit after ANY of these:
- Completed 1-3 tasks from the checklist
- Session context feels large (many tool calls)
- Hit a blocking issue needing user input
- All tasks complete

---

## STATUS

**Current Phase:** ASSESSMENT_NEEDED
**Last Updated:** 2026-01-17
**Last Session:** (none yet)

Progress: [ ] Assessment | [ ] Core Implementation | [ ] TUI Fixes | [ ] Testing | [ ] Documentation | [ ] COMPLETE

---

## TASK CHECKLIST

### Phase 1: Assessment (Do First)
- [ ] 1.1 Read CLAUDE.md standing orders
- [ ] 1.2 Read P50 proposal: `docs/proposals/P50-layered-verification-system.md`
- [ ] 1.3 Check verify.sh --run works: `pl verify --run --feature=setup --depth=basic`
- [ ] 1.4 Check TUI works: run `pl verify` and exit with 'q'
- [ ] 1.5 Document current issues in ISSUES section below

### Phase 2: Core Functionality
- [ ] 2.1 Fix any --run execution issues found in assessment
- [ ] 2.2 Ensure machine.checks execute correctly at all depth levels
- [ ] 2.3 Verify machine.state gets updated after test runs
- [ ] 2.4 Ensure test results persist to .verification.yml

### Phase 3: TUI Display
- [ ] 3.1 TUI shows machine verification status for each item
- [ ] 3.2 TUI shows human verification status for each item
- [ ] 3.3 TUI distinguishes machine vs human verified visually
- [ ] 3.4 Status summary shows accurate counts

### Phase 4: Integration
- [ ] 4.1 Badges generation works (`pl verify --badges`)
- [ ] 4.2 CI/CD integration documented
- [ ] 4.3 All test-nwp.sh references removed/updated
- [ ] 4.4 Run full test suite, fix failures

### Phase 5: Documentation & Completion
- [ ] 5.1 Update ROADMAP.md - mark P50 complete
- [ ] 5.2 Update docs/proposals/P50-*.md - mark implemented
- [ ] 5.3 Final commit with summary
- [ ] 5.4 Report completion to user

---

## ISSUES FOUND

<!-- Claude: Document issues here during assessment -->

*No issues documented yet - run assessment phase first*

---

## SESSION LOG

<!-- Claude: Add entry for each session -->

### Session Template
```
### Session N - YYYY-MM-DD
**Tasks:** X.X, X.X
**Completed:** (list)
**Issues:** (any blockers)
**Next:** (what to do next session)
**Commit:** (commit hash if made)
```

---

## REFERENCE

### Key Files
- Proposal: `docs/proposals/P50-layered-verification-system.md`
- Main script: `scripts/commands/verify.sh`
- Runner lib: `lib/verify-runner.sh`
- Data file: `.verification.yml`
- Standing orders: `CLAUDE.md`

### Key Commands
```bash
# Check status
pl verify --status

# Run machine tests
pl verify --run --depth=basic
pl verify --run --feature=setup --depth=standard

# Launch TUI
pl verify

# Generate badges
pl verify --badges
```

### Success Criteria
1. `pl verify --run` executes tests and updates machine.state
2. `pl verify` TUI shows both machine and human status
3. Badges reflect actual verification status
4. All tests pass (or known failures documented)
5. Documentation updated

---

## COMPLETION CHECKLIST

Before marking COMPLETE:
- [ ] All Phase 1-5 tasks checked
- [ ] No blocking issues in ISSUES section
- [ ] At least one successful test run logged
- [ ] User confirmed satisfaction (or all requirements met)

When complete, update STATUS to:
```
**Current Phase:** COMPLETE
**Completed:** 2026-XX-XX
```

Then say: "P50 implementation complete. All tasks finished."
