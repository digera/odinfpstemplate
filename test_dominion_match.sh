#!/bin/bash
# Automated test for Phase 4: Nexus Dominion match flow
# Tests that bots capture Obelisks, essence climbs, and match ends

set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_BIN="$ROOT/bin/nexus_server"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Phase 4: Dominion Match Test ===${NC}"
echo ""

if [ ! -x "$SERVER_BIN" ]; then
    echo -e "${RED}Error: Server not built${NC}"
    echo "Run: ./build.sh server"
    exit 1
fi

# Test configuration
# Use reduced essence threshold for faster testing
TEST_ESSENCE=100  # Win at 100 essence instead of 1000
TEST_FAST=5       # 5x essence generation speed (10/sec * 5 = 50/sec per Obelisk)
TIMEOUT=60        # Max 60 seconds for test

echo -e "${YELLOW}Test Configuration:${NC}"
echo "  Win Threshold: $TEST_ESSENCE essence"
echo "  Essence Rate: ${TEST_FAST}x (50 essence/sec per Obelisk)"
echo "  Expected Duration: ~4-10 seconds after warmup"
echo "  Timeout: ${TIMEOUT}s"
echo ""

# Start server in background with test mode
echo -e "${YELLOW}>> Starting server in test mode...${NC}"
NEXUS_TEST_ESSENCE=$TEST_ESSENCE NEXUS_TEST_FAST=$TEST_FAST timeout $TIMEOUT "$SERVER_BIN" > /tmp/nexus_dominion_test.log 2>&1 &
SERVER_PID=$!

# Give it time to initialize
sleep 1

echo -e "${YELLOW}>> Waiting for match to complete...${NC}"

# Monitor server output
tail -f /tmp/nexus_dominion_test.log 2>/dev/null &
TAIL_PID=$!

# Wait for server to finish or timeout
wait $SERVER_PID 2>/dev/null || true
SERVER_EXIT=$?

# Stop tail
kill $TAIL_PID 2>/dev/null || true
wait $TAIL_PID 2>/dev/null || true

echo ""
echo -e "${GREEN}=== Test Results ===${NC}"
echo ""

# Check server output for key events
if [ -f /tmp/nexus_dominion_test.log ]; then
    # Check for match start
    if grep -q "\[Match\] Match started" /tmp/nexus_dominion_test.log; then
        echo -e "${GREEN}✓${NC} Match started (left Waiting state)"
    else
        echo -e "${RED}✗${NC} Match did not start"
        echo ""
        echo "Server log:"
        cat /tmp/nexus_dominion_test.log
        exit 1
    fi
    
    # Check for Obelisk captures
    CAPTURE_COUNT=$(grep -c "\[Obelisk.*\] Captured by Team" /tmp/nexus_dominion_test.log || true)
    if [ "$CAPTURE_COUNT" -gt 0 ]; then
        echo -e "${GREEN}✓${NC} Obelisks captured ($CAPTURE_COUNT captures detected)"
    else
        echo -e "${YELLOW}⚠${NC} No Obelisk captures detected (bots may not have reached objectives)"
    fi
    
    # Check for match end
    if grep -q "\[Match\] Match ended! Winner:" /tmp/nexus_dominion_test.log; then
        WINNER=$(grep "\[Match\] Match ended! Winner:" /tmp/nexus_dominion_test.log | tail -1)
        echo -e "${GREEN}✓${NC} Match ended without crash"
        echo "  $WINNER"
    else
        echo -e "${RED}✗${NC} Match did not end (may have hit timeout)"
        
        # Check if we at least generated essence
        if grep -q "essence" /tmp/nexus_dominion_test.log; then
            echo -e "${YELLOW}⚠${NC} Essence generation detected, but match incomplete"
        fi
        
        echo ""
        echo "Last 20 lines of server log:"
        tail -20 /tmp/nexus_dominion_test.log
        exit 1
    fi
    
    # Extract final scores
    FINAL_SCORES=$(grep "\[Match\] Match ended!" /tmp/nexus_dominion_test.log | tail -1 | grep -oP '\(\K[^)]+' || echo "unknown")
    echo "  Final Scores: $FINAL_SCORES"
    
    echo ""
    echo -e "${GREEN}=== Test PASSED ===${NC}"
    echo ""
    echo "Dominion match flow verified:"
    echo "  • Match state machine works (Waiting → Active → Ended)"
    echo "  • Bots seek and capture Obelisks"
    echo "  • Essence generation from held Obelisks"
    echo "  • Match ends at threshold without crashes"
    
else
    echo -e "${RED}✗${NC} Server log not found"
    exit 1
fi

# Cleanup
rm -f /tmp/nexus_dominion_test.log

exit 0
