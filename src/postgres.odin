// PostgreSQL libpq FFI bindings for Phase 5 persistence
package main

import "core:c"

when ODIN_OS == .Linux {
	foreign import libpq "system:pq"
} else when ODIN_OS == .Darwin {
	foreign import libpq "system:pq"
} else when ODIN_OS == .Windows {
	foreign import libpq "system:libpq.lib"
}

// Opaque C types
PGconn :: distinct rawptr
PGresult :: distinct rawptr

// Connection status
ConnStatusType :: enum c.int {
	CONNECTION_OK = 0,
	CONNECTION_BAD = 1,
}

// Result status
ExecStatusType :: enum c.int {
	PGRES_EMPTY_QUERY = 0,
	PGRES_COMMAND_OK = 1,
	PGRES_TUPLES_OK = 2,
	PGRES_FATAL_ERROR = 7,
}

@(default_calling_convention="c")
foreign libpq {
	// Connection
	PQconnectdb :: proc(conninfo: cstring) -> PGconn ---
	PQstatus :: proc(conn: PGconn) -> ConnStatusType ---
	PQerrorMessage :: proc(conn: PGconn) -> cstring ---
	PQfinish :: proc(conn: PGconn) ---
	
	// Query execution
	PQexec :: proc(conn: PGconn, command: cstring) -> PGresult ---
	PQexecParams :: proc(
		conn: PGconn,
		command: cstring,
		nParams: c.int,
		paramTypes: [^]c.uint,  // Oid*
		paramValues: [^]cstring,
		paramLengths: [^]c.int,
		paramFormats: [^]c.int,
		resultFormat: c.int,
	) -> PGresult ---
	
	// Result handling
	PQresultStatus :: proc(res: PGresult) -> ExecStatusType ---
	PQresultErrorMessage :: proc(res: PGresult) -> cstring ---
	PQntuples :: proc(res: PGresult) -> c.int ---
	PQnfields :: proc(res: PGresult) -> c.int ---
	PQgetvalue :: proc(res: PGresult, row: c.int, col: c.int) -> cstring ---
	PQclear :: proc(res: PGresult) ---
}
