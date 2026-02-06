#!/bin/bash
# ScreenGrab Code Audit Script
# Run: bash scripts/audit.sh
# Run one section: bash scripts/audit.sh lint|dead-code|complexity|duplication|coverage|security|sizes

set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$PROJECT/ScreenGrab"
SECTION="${1:-all}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

header() { echo -e "\n${CYAN}=== $1 ===${NC}\n"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
ok() { echo -e "${GREEN}[OK] $1${NC}"; }
fail() { echo -e "${RED}[FAIL] $1${NC}"; }

check_tool() {
    if ! command -v "$1" &>/dev/null; then
        warn "$1 not found. Install with: $2"
        return 1
    fi
    return 0
}

# --- 1. SwiftLint ---
run_lint() {
    header "1. SWIFTLINT (Style + Safety)"
    if ! check_tool swiftlint "brew install swiftlint"; then return; fi
    swiftlint lint --path "$SRC" 2>/dev/null || true
    echo ""
    local count
    count=$(swiftlint lint --path "$SRC" 2>/dev/null | grep -cE "warning:|error:" || true)
    count=${count:-0}
    if [ "$count" -eq 0 ]; then
        ok "No SwiftLint violations"
    else
        warn "$count SwiftLint violations found"
    fi
}

# --- 2. Dead Code ---
run_dead_code() {
    header "2. PERIPHERY (Dead Code)"
    if ! check_tool periphery "brew install peripheryapp/periphery/periphery"; then return; fi
    cd "$PROJECT"
    periphery scan --project-type spm --targets ScreenGrab --quiet 2>/dev/null || true
}

# --- 3. Complexity ---
run_complexity() {
    header "3. LIZARD (Cyclomatic Complexity)"
    if ! check_tool lizard "pip3 install lizard"; then return; fi
    echo "Top 15 most complex functions:"
    echo ""
    lizard -l swift -s cyclomatic_complexity "$SRC" 2>/dev/null | head -20
    echo ""
    echo "Functions exceeding thresholds (CCN>10 or >60 lines):"
    lizard -l swift -C 10 -L 60 -w "$SRC" 2>/dev/null || ok "No functions exceed thresholds"
}

# --- 4. Duplication ---
run_duplication() {
    header "4. PMD CPD (Code Duplication)"
    if ! check_tool pmd "brew install pmd"; then return; fi
    local result
    result=$(pmd cpd --language swift --minimum-tokens 50 --dir "$SRC" 2>/dev/null) || true
    if [ -z "$result" ]; then
        ok "No duplicated code blocks found (>50 tokens)"
    else
        echo "$result"
    fi
}

# --- 5. Coverage ---
run_coverage() {
    header "5. TEST COVERAGE"
    cd "$PROJECT"
    swift test --enable-code-coverage 2>&1 | tail -5

    local binary="$PROJECT/.build/debug/ScreenGrabPackageTests.xctest/Contents/MacOS/ScreenGrabPackageTests"
    local profdata="$PROJECT/.build/debug/codecov/default.profdata"

    if [ -f "$profdata" ] && [ -f "$binary" ]; then
        echo ""
        xcrun llvm-cov report "$binary" -instr-profile="$profdata" \
            -ignore-filename-regex='.build|Tests' 2>/dev/null || true
    else
        warn "Coverage data not found. Run 'swift test --enable-code-coverage' first."
    fi
}

# --- 6. Security ---
run_security() {
    header "6. SECURITY AUDIT"

    echo "Entitlements:"
    if [ -f "$SRC/Resources/ScreenGrab.entitlements" ]; then
        cat "$SRC/Resources/ScreenGrab.entitlements"
    else
        warn "No entitlements file found"
    fi

    echo ""
    echo "Force unwraps (potential crash sites):"
    local force_unwraps
    force_unwraps=$(grep -rn '![^=]' "$SRC" --include="*.swift" | grep -v '//' | grep -v 'IBOutlet' | grep -c '!' || echo "0")
    echo "  Found approximately $force_unwraps lines with '!' (review manually)"

    echo ""
    echo "Force casts:"
    grep -rn ' as! ' "$SRC" --include="*.swift" || ok "No force casts found"

    echo ""
    echo "Force try:"
    grep -rn 'try!' "$SRC" --include="*.swift" || ok "No force try found"

    echo ""
    echo "Hardcoded secrets/keys:"
    grep -rni 'password\|secret\|api.key\|token' "$SRC" --include="*.swift" || ok "No hardcoded secrets found"
}

# --- 7. File Sizes ---
run_sizes() {
    header "7. FILE SIZES (Architecture)"
    echo "Lines per file (descending):"
    find "$SRC" -name "*.swift" -exec wc -l {} + | sort -rn | head -15
    echo ""

    echo "Methods per file:"
    for f in $(find "$SRC" -name "*.swift" | sort); do
        local count
        count=$(grep -cE '^\s*(private |override |static )?func ' "$f" 2>/dev/null || true)
        count=${count:-0}
        local name
        name=$(basename "$f")
        if [ "$count" -gt 5 ]; then
            printf "  %-45s %3d methods\n" "$name" "$count"
        fi
    done

    echo ""
    echo "God object check (types >300 lines):"
    local found=false
    for f in $(find "$SRC" -name "*.swift"); do
        local lines
        lines=$(wc -l < "$f")
        if [ "$lines" -gt 300 ]; then
            warn "$(basename "$f"): $lines lines"
            found=true
        fi
    done
    if [ "$found" = false ]; then
        ok "No files exceed 300 lines"
    fi
}

# --- Run ---
case "$SECTION" in
    lint)        run_lint ;;
    dead-code)   run_dead_code ;;
    complexity)  run_complexity ;;
    duplication) run_duplication ;;
    coverage)    run_coverage ;;
    security)    run_security ;;
    sizes)       run_sizes ;;
    all)
        run_lint
        run_dead_code
        run_complexity
        run_duplication
        run_coverage
        run_security
        run_sizes
        header "AUDIT COMPLETE"
        ;;
    *)
        echo "Usage: bash scripts/audit.sh [lint|dead-code|complexity|duplication|coverage|security|sizes|all]"
        exit 1
        ;;
esac
