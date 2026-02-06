Run a full code audit of the ScreenGrab codebase using parallel agents. This is a READ-ONLY operation — do not modify any files.

Launch these 5 agents IN PARALLEL using the Task tool (subagent_type=Explore for each). Each agent should read all relevant source files and produce a concise report.

## Agent 1: Security Audit
Prompt: "Read every Swift source file in ScreenGrab/ (not .build/ or Tests/). Audit for security issues: force unwraps that could crash, force casts, unsafe file path handling, missing input validation, hardcoded credentials, improper use of UserDefaults for sensitive data, entitlement issues (read ScreenGrab/Resources/ScreenGrab.entitlements), missing error handling that could leak info, and any OWASP-relevant issues for a desktop app. Rate each finding as HIGH/MEDIUM/LOW severity. Be specific — cite file:line for every finding."

## Agent 2: Architecture & Code Quality Audit
Prompt: "Read every Swift source file in ScreenGrab/ (not .build/ or Tests/). Audit the architecture: identify god objects (classes >300 lines or >10 responsibilities), tight coupling between modules, missing abstractions, violation of Single Responsibility Principle, type-casting chains that should use polymorphism, code that belongs in a different file, and any design patterns that would simplify the code. For each finding, suggest what to extract and where. Be specific — cite file:line."

## Agent 3: Performance Audit
Prompt: "Read every Swift source file in ScreenGrab/ (not .build/ or Tests/). Audit for performance issues: unnecessary allocations in hot paths (draw methods, timer callbacks, mouse event handlers), retain cycles from closures or delegates, expensive operations on the main thread, inefficient algorithms, unnecessary view redraws, timer/polling that should be event-driven, layers or objects not properly cleaned up. Be specific — cite file:line for every finding."

## Agent 4: Bug & Edge Case Audit
Prompt: "Read every Swift source file in ScreenGrab/ (not .build/ or Tests/). Look for actual bugs and unhandled edge cases: race conditions, state machine inconsistencies (check all CaptureMode transitions), nil dereferences, array out-of-bounds risks, division by zero, incomplete cleanup on cancel/close, missing guard clauses, off-by-one errors, and any logic that looks subtly wrong. Check undo/redo edge cases too. Be specific — cite file:line."

## Agent 5: Test Coverage Gap Analysis
Prompt: "Read every Swift source file in ScreenGrab/ AND every test file in Tests/. Compare what's tested vs what's not. Identify: (1) public/internal methods with zero test coverage, (2) complex logic paths that have no tests, (3) edge cases that existing tests miss, (4) the most impactful tests that could be added (highest risk untested code). Prioritize by risk — what bugs would hurt users most? List the top 10 most important missing tests with what they should verify."

## Output Format
After all agents complete, synthesize their results into a single audit report with these sections:
1. **Critical** — things to fix now (crashes, security holes, data loss risks)
2. **Important** — significant quality issues worth addressing soon
3. **Minor** — nice-to-haves and polish items
4. **Metrics** — file sizes, method counts, estimated coverage gaps

Deduplicate findings across agents. Keep each finding to 1-2 lines with file:line references.
