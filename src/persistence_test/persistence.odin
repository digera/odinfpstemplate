// Phase 5: Persistence Layer
// Event-sourced item ledger + accounts
package main

import "core:fmt"
import "core:strings"
import "core:strconv"
import "core:c"

// Persistence store (PostgreSQL connection)
Persistence_Store :: struct {
	conn: PGconn,
	connected: bool,
}

// Account data
Account :: struct {
	account_id: i64,
	display_name: string,
}

// Item definition
Item_Def :: struct {
	item_def_id: i32,
	item_name: string,
	item_type: string,
	stack_max: i32,
}

// Item instance (owned by account)
Item_Instance :: struct {
	item_instance_id: i64,
	account_id: i64,
	item_def_id: i32,
	stack_count: i32,
}

// Ledger entry type
Ledger_Entry_Type :: enum {
	Grant,    // Give item to account
	Consume,  // Remove item from account
	Transfer, // Transfer between accounts
}

// Ledger entry (event sourcing)
Ledger_Entry :: struct {
	ledger_id: i64,
	account_id: i64,
	entry_type: Ledger_Entry_Type,
	item_def_id: i32,
	quantity: i32,
	related_account_id: i64,  // For transfers
	reason: string,
}

// Initialize persistence store
persistence_init :: proc(conn_string: cstring) -> (store: Persistence_Store, ok: bool) {
	conn := PQconnectdb(conn_string)
	if PQstatus(conn) != .CONNECTION_OK {
		fmt.eprintln("[Persistence] Connection failed:", string(PQerrorMessage(conn)))
		PQfinish(conn)
		return {}, false
	}
	
	fmt.println("[Persistence] Connected to PostgreSQL")
	store.conn = conn
	store.connected = true
	return store, true
}

// Cleanup
persistence_shutdown :: proc(store: ^Persistence_Store) {
	if store.connected {
		PQfinish(store.conn)
		store.connected = false
		fmt.println("[Persistence] Disconnected")
	}
}

// Create account
persistence_create_account :: proc(store: ^Persistence_Store, display_name: string) -> (account_id: i64, ok: bool) {
	if !store.connected {
		return 0, false
	}
	
	query := fmt.ctprintf("INSERT INTO accounts (display_name) VALUES ('%s') RETURNING account_id", display_name)
	res := PQexec(store.conn, query)
	defer PQclear(res)
	
	if PQresultStatus(res) != .PGRES_TUPLES_OK {
		fmt.eprintln("[Persistence] Create account failed:", string(PQresultErrorMessage(res)))
		return 0, false
	}
	
	if PQntuples(res) > 0 {
		id_str := string(PQgetvalue(res, 0, 0))
		account_id = strconv.parse_i64(id_str) or_else 0
		fmt.printf("[Persistence] Created account: %s (ID: %d)\n", display_name, account_id)
		return account_id, true
	}
	
	return 0, false
}

// Get account by name
persistence_get_account :: proc(store: ^Persistence_Store, display_name: string) -> (account: Account, ok: bool) {
	if !store.connected {
		return {}, false
	}
	
	query := fmt.ctprintf("SELECT account_id, display_name FROM accounts WHERE display_name = '%s'", display_name)
	res := PQexec(store.conn, query)
	defer PQclear(res)
	
	if PQresultStatus(res) != .PGRES_TUPLES_OK {
		return {}, false
	}
	
	if PQntuples(res) > 0 {
		account.account_id = strconv.parse_i64(string(PQgetvalue(res, 0, 0))) or_else 0
		account.display_name = strings.clone(string(PQgetvalue(res, 0, 1)))
		return account, true
	}
	
	return {}, false
}

// Grant item to account (ledger transaction)
persistence_grant_item :: proc(store: ^Persistence_Store, account_id: i64, item_def_id: i32, quantity: i32, reason: string) -> bool {
	if !store.connected || quantity <= 0 {
		return false
	}
	
	// Begin transaction
	res := PQexec(store.conn, "BEGIN")
	PQclear(res)
	
	// Insert ledger entry
	ledger_query := fmt.ctprintf(
		"INSERT INTO ledger_entries (account_id, entry_type, item_def_id, quantity, reason) VALUES (%d, 'grant', %d, %d, '%s')",
		account_id, item_def_id, quantity, reason,
	)
	res = PQexec(store.conn, ledger_query)
	if PQresultStatus(res) != .PGRES_COMMAND_OK {
		PQclear(res)
		PQexec(store.conn, "ROLLBACK")
		return false
	}
	PQclear(res)
	
	// Update or insert item instance
	// First, try to find existing instance
	check_query := fmt.ctprintf(`
		SELECT item_instance_id, stack_count FROM item_instances 
		WHERE account_id = %d AND item_def_id = %d`,
		account_id, item_def_id,
	)
	check_res := PQexec(store.conn, check_query)
	defer PQclear(check_res)
	
	if PQresultStatus(check_res) == .PGRES_TUPLES_OK && PQntuples(check_res) > 0 {
		// Update existing
		instance_id := strconv.parse_i64(string(PQgetvalue(check_res, 0, 0))) or_else 0
		current_count := i32(strconv.parse_int(string(PQgetvalue(check_res, 0, 1))) or_else 0)
		new_count := current_count + quantity
		
		update_query := fmt.ctprintf(`
			UPDATE item_instances SET stack_count = %d WHERE item_instance_id = %d`,
			new_count, instance_id,
		)
		res = PQexec(store.conn, update_query)
	} else {
		// Insert new
		insert_query := fmt.ctprintf(`
			INSERT INTO item_instances (account_id, item_def_id, stack_count)
			VALUES (%d, %d, %d)`,
			account_id, item_def_id, quantity,
		)
		res = PQexec(store.conn, insert_query)
	}
	if PQresultStatus(res) != .PGRES_COMMAND_OK {
		PQclear(res)
		PQexec(store.conn, "ROLLBACK")
		return false
	}
	PQclear(res)
	
	// Commit
	res = PQexec(store.conn, "COMMIT")
	PQclear(res)
	
	fmt.printf("[Persistence] Granted %dx item %d to account %d (%s)\n", quantity, item_def_id, account_id, reason)
	return true
}

// Get inventory for account
persistence_get_inventory :: proc(store: ^Persistence_Store, account_id: i64, allocator := context.allocator) -> []Item_Instance {
	if !store.connected {
		return nil
	}
	
	query := fmt.ctprintf(
		"SELECT item_instance_id, account_id, item_def_id, stack_count FROM item_instances WHERE account_id = %d",
		account_id,
	)
	res := PQexec(store.conn, query)
	defer PQclear(res)
	
	if PQresultStatus(res) != .PGRES_TUPLES_OK {
		return nil
	}
	
	count := int(PQntuples(res))
	if count == 0 {
		return nil
	}
	
	items := make([]Item_Instance, count, allocator)
	for i in 0..<count {
		items[i].item_instance_id = strconv.parse_i64(string(PQgetvalue(res, c.int(i), 0))) or_else 0
		items[i].account_id = strconv.parse_i64(string(PQgetvalue(res, c.int(i), 1))) or_else 0
		items[i].item_def_id = i32(strconv.parse_int(string(PQgetvalue(res, c.int(i), 2))) or_else 0)
		items[i].stack_count = i32(strconv.parse_int(string(PQgetvalue(res, c.int(i), 3))) or_else 0)
	}
	
	return items
}

// Get ledger history for account (last N entries)
persistence_get_ledger :: proc(store: ^Persistence_Store, account_id: i64, limit: int = 100, allocator := context.allocator) -> []Ledger_Entry {
	if !store.connected {
		return nil
	}
	
	query := fmt.ctprintf(
		"SELECT ledger_id, account_id, entry_type, item_def_id, quantity, related_account_id, reason FROM ledger_entries WHERE account_id = %d ORDER BY ledger_id DESC LIMIT %d",
		account_id, limit,
	)
	res := PQexec(store.conn, query)
	defer PQclear(res)
	
	if PQresultStatus(res) != .PGRES_TUPLES_OK {
		return nil
	}
	
	count := int(PQntuples(res))
	if count == 0 {
		return nil
	}
	
	entries := make([]Ledger_Entry, count, allocator)
	for i in 0..<count {
		entries[i].ledger_id = strconv.parse_i64(string(PQgetvalue(res, c.int(i), 0))) or_else 0
		entries[i].account_id = strconv.parse_i64(string(PQgetvalue(res, c.int(i), 1))) or_else 0
		
		entry_type_str := string(PQgetvalue(res, c.int(i), 2))
		switch entry_type_str {
		case "grant": entries[i].entry_type = .Grant
		case "consume": entries[i].entry_type = .Consume
		case "transfer": entries[i].entry_type = .Transfer
		}
		
		entries[i].item_def_id = i32(strconv.parse_int(string(PQgetvalue(res, c.int(i), 3))) or_else 0)
		entries[i].quantity = i32(strconv.parse_int(string(PQgetvalue(res, c.int(i), 4))) or_else 0)
		entries[i].related_account_id = strconv.parse_i64(string(PQgetvalue(res, c.int(i), 5))) or_else 0
		entries[i].reason = strings.clone(string(PQgetvalue(res, c.int(i), 6)))
	}
	
	return entries
}
