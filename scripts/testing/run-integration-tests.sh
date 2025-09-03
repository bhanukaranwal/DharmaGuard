#!/bin/bash
# DharmaGuard Integration Testing Suite
# Comprehensive end-to-end testing for all platform components

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
API_BASE_URL="${API_BASE_URL:-http://localhost:8080}"
FRONTEND_URL="${FRONTEND_URL:-http://localhost:3000}"
TEST_TIMEOUT="${TEST_TIMEOUT:-300}"
MAX_RETRIES="${MAX_RETRIES:-3}"

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Wait for service to be ready
wait_for_service() {
    local service_name=$1
    local health_url=$2
    local timeout=${3:-60}
    
    log_info "Waiting for $service_name to be ready..."
    
    local count=0
    while [ $count -lt $timeout ]; do
        if curl -sf "$health_url" >/dev/null 2>&1; then
            log_success "$service_name is ready"
            return 0
        fi
        sleep 1
        ((count++))
    done
    
    log_error "$service_name failed to become ready within $timeout seconds"
    return 1
}

# Execute test with retry logic
execute_test() {
    local test_name=$1
    local test_command=$2
    local retries=${3:-$MAX_RETRIES}
    
    log_info "Running test: $test_name"
    
    for ((i=1; i<=retries; i++)); do
        if timeout $TEST_TIMEOUT bash -c "$test_command"; then
            log_success "✓ $test_name passed"
            ((TESTS_PASSED++))
            return 0
        else
            if [ $i -eq $retries ]; then
                log_error "✗ $test_name failed after $retries attempts"
                ((TESTS_FAILED++))
                return 1
            else
                log_warning "Attempt $i/$retries failed, retrying..."
                sleep 2
            fi
        fi
    done
}

# Generate test JWT token
generate_test_token() {
    local response=$(curl -s -X POST "$API_BASE_URL/api/v1/auth/login" \
        -H "Content-Type: application/json" \
        -d '{"username":"test_admin","password":"test_password"}')
    
    if [ $? -eq 0 ]; then
        echo "$response" | jq -r '.access_token'
    else
        log_error "Failed to generate test token"
        return 1
    fi
}

# Test health endpoints
test_health_endpoints() {
    log_info "Testing health endpoints..."
    
    local services=(
        "API Gateway:$API_BASE_URL/health"
        "User Service:$API_BASE_URL/api/v1/users/health"
        "Compliance Service:$API_BASE_URL/api/v1/compliance/health"
        "Reporting Service:$API_BASE_URL/api/v1/reports/health"
        "Audit Service:$API_BASE_URL/api/v1/audit/health"
        "Frontend:$FRONTEND_URL/health"
    )
    
    for service in "${services[@]}"; do
        IFS=':' read -r name url <<< "$service"
        execute_test "Health check - $name" "curl -sf '$url'"
    done
}

# Test authentication flow
test_authentication() {
    log_info "Testing authentication flow..."
    
    # Test login
    execute_test "User login" "
        response=\$(curl -s -X POST '$API_BASE_URL/api/v1/auth/login' \
            -H 'Content-Type: application/json' \
            -d '{\"username\":\"test_admin\",\"password\":\"test_password\"}')
        echo \"\$response\" | jq -e '.access_token'
    "
    
    # Test protected endpoint without token
    execute_test "Protected endpoint without token (should fail)" "
        response=\$(curl -s -w '%{http_code}' -X GET '$API_BASE_URL/api/v1/users')
        [ \"\${response: -3}\" = \"401\" ]
    "
    
    # Test protected endpoint with token
    local token=$(generate_test_token)
    if [ -n "$token" ] && [ "$token" != "null" ]; then
        execute_test "Protected endpoint with token" "
            curl -sf -X GET '$API_BASE_URL/api/v1/users' \
                -H 'Authorization: Bearer $token'
        "
    else
        log_warning "Skipping token-based tests - unable to generate token"
        ((TESTS_SKIPPED++))
    fi
}

# Test user management
test_user_management() {
    log_info "Testing user management..."
    
    local token=$(generate_test_token)
    if [ -z "$token" ] || [ "$token" = "null" ]; then
        log_warning "Skipping user management tests - no auth token"
        ((TESTS_SKIPPED++))
        return
    fi
    
    # Create test user
    execute_test "Create user" "
        response=\$(curl -s -X POST '$API_BASE_URL/api/v1/users' \
            -H 'Authorization: Bearer $token' \
            -H 'Content-Type: application/json' \
            -d '{
                \"username\":\"integration_test_user\",
                \"email\":\"test@example.com\",
                \"password\":\"SecurePassword123!\",
                \"role\":\"TRADER\",
                \"tenant_id\":\"550e8400-e29b-41d4-a716-446655440000\"
            }')
        echo \"\$response\" | jq -e '.user_id'
    "
    
    # List users
    execute_test "List users" "
        curl -sf -X GET '$API_BASE_URL/api/v1/users' \
            -H 'Authorization: Bearer $token' | jq -e '.data | length > 0'
    "
}

# Test surveillance system
test_surveillance_system() {
    log_info "Testing surveillance system..."
    
    local token=$(generate_test_token)
    if [ -z "$token" ] || [ "$token" = "null" ]; then
        log_warning "Skipping surveillance tests - no auth token"
        ((TESTS_SKIPPED++))
        return
    fi
    
    # Submit test trade
    execute_test "Submit test trade" "
        curl -sf -X POST '$API_BASE_URL/api/v1/surveillance/trades' \
            -H 'Authorization: Bearer $token' \
            -H 'Content-Type: application/json' \
            -d '{
                \"trade_id\":\"test_trade_001\",
                \"tenant_id\":\"550e8400-e29b-41d4-a716-446655440000\",
                \"account_id\":\"acc_001\",
                \"instrument\":\"RELIANCE\",
                \"trade_type\":\"BUY\",
                \"quantity\":100,
                \"price\":2500.50,
                \"exchange\":\"NSE\",
                \"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
            }'
    "
    
    # Get surveillance statistics
    execute_test "Get surveillance statistics" "
        curl -sf -X GET '$API_BASE_URL/api/v1/surveillance/statistics' \
            -H 'Authorization: Bearer $token' | jq -e '.total_trades_processed'
    "
    
    # Get alerts
    execute_test "Get surveillance alerts" "
        curl -sf -X GET '$API_BASE_URL/api/v1/surveillance/alerts' \
            -H 'Authorization: Bearer $token' | jq -e '.data'
    "
}

# Test compliance reporting
test_compliance_reporting() {
    log_info "Testing compliance reporting..."
    
    local token=$(generate_test_token)
    if [ -z "$token" ] || [ "$token" = "null" ]; then
        log_warning "Skipping compliance tests - no auth token"
        ((TESTS_SKIPPED++))
        return
    fi
    
    # Generate compliance report
    execute_test "Generate compliance report" "
        response=\$(curl -s -X POST '$API_BASE_URL/api/v1/compliance/reports' \
            -H 'Authorization: Bearer $token' \
            -H 'Content-Type: application/json' \
            -d '{
                \"report_type\":\"DAILY_TRADING_SUMMARY\",
                \"period_start\":\"$(date -d '1 day ago' +%Y-%m-%d)\",
                \"period_end\":\"$(date +%Y-%m-%d)\",
                \"format\":\"JSON\"
            }')
        echo \"\$response\" | jq -e '.report_id'
    "
    
    # List reports
    execute_test "List compliance reports" "
        curl -sf -X GET '$API_BASE_URL/api/v1/compliance/reports' \
            -H 'Authorization: Bearer $token' | jq -e '.data'
    "
}

# Test audit trail
test_audit_trail() {
    log_info "Testing audit trail..."
    
    local token=$(generate_test_token)
    if [ -z "$token" ] || [ "$token" = "null" ]; then
        log_warning "Skipping audit tests - no auth token"
        ((TESTS_SKIPPED++))
        return
    fi
    
    # Create audit event
    execute_test "Create audit event" "
        curl -sf -X POST '$API_BASE_URL/api/v1/audit/events' \
            -H 'Authorization: Bearer $token' \
            -H 'Content-Type: application/json' \
            -d '{
                \"tenant_id\":\"550e8400-e29b-41d4-a716-446655440000\",
                \"action\":\"CREATE_USER\",
                \"resource_type\":\"USER\",
                \"resource_id\":\"550e8400-e29b-41d4-a716-446655440001\"
            }'
    "
    
    # Get audit trail
    execute_test "Get audit trail" "
        curl -sf -X GET '$API_BASE_URL/api/v1/audit/events?tenant_id=550e8400-e29b-41d4-a716-446655440000' \
            -H 'Authorization: Bearer $token' | jq -e '.events'
    "
}

# Test performance under load
test_performance() {
    log_info "Testing performance under load..."
    
    if ! command -v ab &> /dev/null; then
        log_warning "Apache Bench (ab) not found, skipping performance tests"
        ((TESTS_SKIPPED++))
        return
    fi
    
    execute_test "API Gateway performance test" "
        ab -n 100 -c 10 -T 'application/json' '$API_BASE_URL/health' | grep -q 'Complete requests:.*100'
    "
}

# Test database connectivity
test_database_connectivity() {
    log_info "Testing database connectivity..."
    
    # Test PostgreSQL connection
    execute_test "PostgreSQL connectivity" "
        docker exec dharmaguard-postgres-dev pg_isready -U dharmaguard -d dharmaguard
    "
    
    # Test Redis connection
    execute_test "Redis connectivity" "
        docker exec dharmaguard-redis-dev redis-cli ping | grep -q PONG
    "
    
    # Test ClickHouse connection
    execute_test "ClickHouse connectivity" "
        curl -sf 'http://localhost:8123/ping' | grep -q OK
    "
}

# Test frontend availability
test_frontend() {
    log_info "Testing frontend availability..."
    
    execute_test "Frontend home page" "
        curl -sf '$FRONTEND_URL' | grep -q 'DharmaGuard'
    "
    
    execute_test "Frontend API connectivity" "
        curl -sf '$FRONTEND_URL/api/health' || curl -sf '$FRONTEND_URL/health'
    "
}

# Cleanup test data
cleanup_test_data() {
    log_info "Cleaning up test data..."
    
    local token=$(generate_test_token)
    if [ -n "$token" ] && [ "$token" != "null" ]; then
        # Clean up test user if created
        curl -sf -X DELETE "$API_BASE_URL/api/v1/users/integration_test_user" \
            -H "Authorization: Bearer $token" || true
    fi
    
    log_success "Test data cleanup completed"
}

# Main test execution
main() {
    echo "========================================"
    echo "  DharmaGuard Integration Test Suite   "
    echo "========================================"
    echo
    
    log_info "Starting integration tests..."
    log_info "API Base URL: $API_BASE_URL"
    log_info "Frontend URL: $FRONTEND_URL"
    log_info "Test Timeout: ${TEST_TIMEOUT}s"
    echo
    
    # Wait for core services to be ready
    wait_for_service "API Gateway" "$API_BASE_URL/health" 60
    wait_for_service "Frontend" "$FRONTEND_URL" 60
    
    # Run test suites
    test_health_endpoints
    test_database_connectivity
    test_authentication
    test_user_management
    test_surveillance_system
    test_compliance_reporting
    test_audit_trail
    test_frontend
    test_performance
    
    # Cleanup
    cleanup_test_data
    
    # Print results
    echo
    echo "========================================"
    echo "           Test Results Summary         "
    echo "========================================"
    echo -e "${GREEN}Tests Passed:  $TESTS_PASSED${NC}"
    echo -e "${RED}Tests Failed:   $TESTS_FAILED${NC}"
    echo -e "${YELLOW}Tests Skipped:  $TESTS_SKIPPED${NC}"
    echo "Total Tests:   $((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))"
    echo
    
    if [ $TESTS_FAILED -eq 0 ]; then
        log_success "All tests passed! ✨"
        exit 0
    else
        log_error "$TESTS_FAILED tests failed!"
        exit 1
    fi
}

# Run main function
main "$@"
