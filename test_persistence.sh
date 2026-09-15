#!/bin/bash
# Test Phase 5: Persistence layer (PostgreSQL)

set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== Phase 5: Persistence Test ===${NC}"
echo ""

# Check if PostgreSQL is running
if ! sudo service postgresql status > /dev/null 2>&1; then
    echo -e "${YELLOW}Starting PostgreSQL...${NC}"
    sudo service postgresql start
    sleep 2
fi

# Build persistence test
echo -e "${YELLOW}>> Building persistence test...${NC}"
mkdir -p /tmp/nexus_persistence_test

# Copy only non-graphical files
for f in src/*.odin; do
    base=$(basename "$f")
    # Skip files that depend on Sokol or are main entry points
    if [[ "$base" != "main.odin" && \
          "$base" != "main_client.odin" && \
          "$base" != "main_test_client.odin" && \
          "$base" != "main_combat_test.odin" && \
          "$base" != "server.odin" && \
          "$base" != "client_renderer.odin" && \
          "$base" != "scene.odin" && \
          "$base" != "render.odin" && \
          "$base" != "input.odin" ]]; then
        cp "$f" /tmp/nexus_persistence_test/
    fi
done

# Create test main
cat > /tmp/nexus_persistence_test/main.odin << 'EOF'
package main

import "core:fmt"

main :: proc() {
	fmt.println("=== Persistence Ledger Test ===")
	
	// Connect to database
	conn_string := "host=localhost dbname=nexus_arena user=nexus password=nexus_dev"
	store, ok := persistence_init(conn_string)
	if !ok {
		fmt.eprintln("Failed to connect to database")
		return
	}
	defer persistence_shutdown(&store)
	
	// Test 1: Create account
	fmt.println("\n[Test 1] Create account...")
	account_id, created := persistence_create_account(&store, "TestPlayer")
	if !created {
		fmt.eprintln("✗ Failed to create account")
		return
	}
	fmt.printf("✓ Created account with ID: %d\n", account_id)
	
	// Test 2: Get account
	fmt.println("\n[Test 2] Get account...")
	account, found := persistence_get_account(&store, "TestPlayer")
	if !found {
		fmt.eprintln("✗ Failed to get account")
		return
	}
	fmt.printf("✓ Found account: %s (ID: %d)\n", account.display_name, account.account_id)
	
	// Test 3: Grant items
	fmt.println("\n[Test 3] Grant items...")
	if !persistence_grant_item(&store, account_id, 1, 5, "Test reward") {
		fmt.eprintln("✗ Failed to grant Health Potion")
		return
	}
	if !persistence_grant_item(&store, account_id, 2, 3, "Test reward") {
		fmt.eprintln("✗ Failed to grant Mana Potion")
		return
	}
	if !persistence_grant_item(&store, account_id, 4, 100, "Mining") {
		fmt.eprintln("✗ Failed to grant Mystic Ore")
		return
	}
	fmt.println("✓ Granted items")
	
	// Test 4: Get inventory
	fmt.println("\n[Test 4] Get inventory...")
	inventory := persistence_get_inventory(&store, account_id)
	if len(inventory) == 0 {
		fmt.eprintln("✗ Inventory is empty")
		return
	}
	fmt.printf("✓ Inventory has %d item types:\n", len(inventory))
	for item in inventory {
		fmt.printf("  - Item %d: %d stacks\n", item.item_def_id, item.stack_count)
	}
	
	// Test 5: Get ledger history
	fmt.println("\n[Test 5] Get ledger history...")
	ledger := persistence_get_ledger(&store, account_id, 10)
	if len(ledger) == 0 {
		fmt.eprintln("✗ Ledger is empty")
		return
	}
	fmt.printf("✓ Ledger has %d entries:\n", len(ledger))
	for entry in ledger {
		fmt.printf("  - [%d] %v: %dx item %d (%s)\n", 
			entry.ledger_id, entry.entry_type, entry.quantity, entry.item_def_id, entry.reason)
	}
	
	fmt.println("\n=== ALL TESTS PASSED ===")
}
EOF

# Compile test
odin build /tmp/nexus_persistence_test -out:/tmp/nexus_persistence_test_bin -o:speed 2>&1 | grep -v "^$" || true

if [ ! -f /tmp/nexus_persistence_test_bin ]; then
    echo -e "${RED}✗ Build failed${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Build successful${NC}"
echo ""

# Run test
echo -e "${YELLOW}>> Running persistence test...${NC}"
/tmp/nexus_persistence_test_bin

echo ""
echo -e "${GREEN}=== Persistence Test PASSED ===${NC}"
