#!/bin/bash
# Test script for Phase 2 - runs server and test client

echo "=== Phase 2 Test: Client Prediction & Network ==="
echo ""

# Kill any existing server
pkill -f nexus_server 2>/dev/null || true
sleep 1

# Start server in background
echo "[1] Starting server..."
./bin/nexus_server > /tmp/server_test.log 2>&1 &
SERVER_PID=$!
echo "    Server PID: $SERVER_PID"

# Wait for server to initialize
sleep 2

# Run test client
echo "[2] Starting test client (will run 30 seconds)..."
echo ""
./bin/nexus_client_test 2>&1 | tee /tmp/client_test.log

# Kill server
echo ""
echo "[3] Stopping server..."
kill $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true

# Show results
echo ""
echo "=== Test Results ==="
echo ""
echo "Server log (last 20 lines):"
tail -20 /tmp/server_test.log
echo ""
echo "Client summary:"
grep "Stats @" /tmp/client_test.log | tail -5
echo ""
grep "Test Complete" /tmp/client_test.log -A 5
echo ""
echo "Full logs:"
echo "  Server: /tmp/server_test.log"
echo "  Client: /tmp/client_test.log"
