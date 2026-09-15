package main

import "core:fmt"

main :: proc() {
	fmt.println("=== Persistence Ledger Test ===")
	
	// Connect to database
	conn_string := cstring("host=localhost dbname=nexus_arena user=nexus password=nexus_dev")
	store, ok := persistence_init(conn_string)
	if !ok {
		fmt.eprintln("Failed to connect to database")
		return
	}
	defer persistence_shutdown(&store)
	
	// Test 1: Create or get account
	fmt.println("\n[Test 1] Create or get account...")
	account_id, created := persistence_create_account(&store, "TestPlayer")
	if !created {
		// Try to get existing account
		account, found := persistence_get_account(&store, "TestPlayer")
		if !found {
			fmt.eprintln("✗ Failed to create or get account")
			return
		}
		account_id = account.account_id
		fmt.printf("✓ Using existing account with ID: %d\n", account_id)
	} else {
		fmt.printf("✓ Created new account with ID: %d\n", account_id)
	}
	
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
