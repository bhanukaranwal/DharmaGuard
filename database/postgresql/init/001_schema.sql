-- PostgreSQL Schema Initialization for DharmaGuard Compliance Platform
-- Version: 1.0.0
-- Description: Core database schema for multi-tenant compliance system

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "btree_gin";

-- Create custom types
CREATE TYPE user_role AS ENUM ('SUPER_ADMIN', 'TENANT_ADMIN', 'COMPLIANCE_OFFICER', 'TRADER', 'VIEWER');
CREATE TYPE trade_type AS ENUM ('BUY', 'SELL', 'SHORT_SELL', 'COVER');
CREATE TYPE market_segment AS ENUM ('EQUITY', 'FUTURES', 'OPTIONS', 'COMMODITY', 'CURRENCY');
CREATE TYPE alert_severity AS ENUM ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL');
CREATE TYPE alert_status AS ENUM ('OPEN', 'INVESTIGATING', 'RESOLVED', 'FALSE_POSITIVE');

-- ===========================================
-- CORE TENANT MANAGEMENT
-- ===========================================

-- Tenants table for multi-tenancy
CREATE TABLE tenants (
    tenant_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL UNIQUE,
    display_name VARCHAR(255) NOT NULL,
    sebi_registration_no VARCHAR(50) UNIQUE,
    contact_email VARCHAR(255) NOT NULL,
    contact_phone VARCHAR(20),
    address TEXT,
    subscription_plan VARCHAR(50) DEFAULT 'BASIC',
    max_users INTEGER DEFAULT 10,
    max_trades_per_day INTEGER DEFAULT 10000,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    CONSTRAINT chk_tenant_name CHECK (length(name) >= 3),
    CONSTRAINT chk_subscription_plan CHECK (subscription_plan IN ('BASIC', 'PROFESSIONAL', 'ENTERPRISE'))
);

-- Tenant configurations
CREATE TABLE tenant_configurations (
    config_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    config_key VARCHAR(100) NOT NULL,
    config_value JSONB NOT NULL,
    description TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    UNIQUE(tenant_id, config_key)
);

-- ===========================================
-- USER MANAGEMENT
-- ===========================================

-- Users table with enhanced security features
CREATE TABLE users (
    user_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    username VARCHAR(100) NOT NULL,
    email VARCHAR(255) NOT NULL,
    password_hash TEXT NOT NULL,
    salt TEXT NOT NULL,
    role user_role NOT NULL DEFAULT 'VIEWER',
    is_active BOOLEAN DEFAULT TRUE,
    is_verified BOOLEAN DEFAULT FALSE,
    mfa_enabled BOOLEAN DEFAULT FALSE,
    mfa_secret TEXT,
    failed_login_attempts INTEGER DEFAULT 0,
    locked_until TIMESTAMPTZ,
    last_login_at TIMESTAMPTZ,
    last_password_change TIMESTAMPTZ DEFAULT NOW(),
    password_expires_at TIMESTAMPTZ DEFAULT (NOW() + INTERVAL '90 days'),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    CONSTRAINT unique_username_per_tenant UNIQUE (tenant_id, username),
    CONSTRAINT unique_email_per_tenant UNIQUE (tenant_id, email),
    CONSTRAINT chk_username_length CHECK (length(username) >= 3),
    CONSTRAINT chk_email_format CHECK (email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
);

-- User sessions for session management
CREATE TABLE user_sessions (
    session_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    session_token TEXT NOT NULL UNIQUE,
    expires_at TIMESTAMPTZ NOT NULL,
    ip_address INET,
    user_agent TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- User permissions for granular access control
CREATE TABLE user_permissions (
    permission_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    resource VARCHAR(100) NOT NULL,
    action VARCHAR(50) NOT NULL,
    granted_at TIMESTAMPTZ DEFAULT NOW(),
    granted_by UUID REFERENCES users(user_id),
    
    UNIQUE(user_id, resource, action)
);

-- ===========================================
-- TRADING SYSTEM
-- ===========================================

-- Trading accounts
CREATE TABLE trading_accounts (
    account_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    account_number VARCHAR(50) NOT NULL,
    account_name VARCHAR(255) NOT NULL,
    account_type VARCHAR(50) NOT NULL,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    CONSTRAINT unique_account_per_tenant UNIQUE (tenant_id, account_number)
);

-- Instruments master data
CREATE TABLE instruments (
    instrument_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    symbol VARCHAR(50) NOT NULL,
    isin VARCHAR(12),
    exchange VARCHAR(10) NOT NULL,
    segment market_segment NOT NULL,
    lot_size INTEGER DEFAULT 1,
    tick_size DECIMAL(10,4) DEFAULT 0.05,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    CONSTRAINT unique_symbol_exchange UNIQUE (symbol, exchange)
);

-- Trade records with comprehensive details
CREATE TABLE trades (
    trade_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES trading_accounts(account_id),
    instrument_id UUID NOT NULL REFERENCES instruments(instrument_id),
    user_id UUID REFERENCES users(user_id),
    order_id VARCHAR(50) NOT NULL,
    trade_number VARCHAR(50) NOT NULL,
    trade_type trade_type NOT NULL,
    quantity BIGINT NOT NULL CHECK (quantity > 0),
    price DECIMAL(20,8) NOT NULL CHECK (price > 0),
    value DECIMAL(25,8) NOT NULL,
    brokerage DECIMAL(15,8) DEFAULT 0,
    taxes DECIMAL(15,8) DEFAULT 0,
    net_amount DECIMAL(25,8) NOT NULL,
    trade_time TIMESTAMPTZ NOT NULL,
    settlement_date DATE,
    exchange VARCHAR(10) NOT NULL,
    segment market_segment NOT NULL,
    client_code VARCHAR(50),
    trader_id VARCHAR(50),
    is_own_account BOOLEAN DEFAULT FALSE,
    remarks TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    
    CONSTRAINT chk_positive_values CHECK (price > 0 AND quantity > 0 AND value > 0)
);

-- Order book for complete order lifecycle
CREATE TABLE orders (
    order_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES trading_accounts(account_id),
    instrument_id UUID NOT NULL REFERENCES instruments(instrument_id),
    client_order_id VARCHAR(50) NOT NULL,
    order_type VARCHAR(20) NOT NULL, -- LIMIT, MARKET, STOP_LOSS
    trade_type trade_type NOT NULL,
    quantity BIGINT NOT NULL,
    price DECIMAL(20,8),
    trigger_price DECIMAL(20,8),
    disclosed_quantity BIGINT DEFAULT 0,
    validity VARCHAR(10) DEFAULT 'DAY', -- DAY, IOC, GTD
    status VARCHAR(20) DEFAULT 'PENDING',
    filled_quantity BIGINT DEFAULT 0,
    remaining_quantity BIGINT,
    average_price DECIMAL(20,8),
    order_time TIMESTAMPTZ NOT NULL,
    last_modified TIMESTAMPTZ DEFAULT NOW(),
    exchange VARCHAR(10) NOT NULL,
    segment market_segment NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ===========================================
-- SURVEILLANCE SYSTEM
-- ===========================================

-- Surveillance patterns configuration
CREATE TABLE surveillance_patterns (
    pattern_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    pattern_name VARCHAR(100) NOT NULL UNIQUE,
    description TEXT NOT NULL,
    algorithm_type VARCHAR(50) NOT NULL,
    parameters JSONB NOT NULL,
    threshold_config JSONB NOT NULL,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Surveillance alerts
CREATE TABLE surveillance_alerts (
    alert_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    pattern_id UUID NOT NULL REFERENCES surveillance_patterns(pattern_id),
    account_id UUID REFERENCES trading_accounts(account_id),
    instrument_id UUID REFERENCES instruments(instrument_id),
    trade_ids UUID[] DEFAULT '{}',
    order_ids UUID[] DEFAULT '{}',
    alert_type VARCHAR(100) NOT NULL,
    severity alert_severity NOT NULL,
    status alert_status DEFAULT 'OPEN',
    title VARCHAR(255) NOT NULL,
    description TEXT NOT NULL,
    risk_score DECIMAL(5,2) NOT NULL CHECK (risk_score >= 0 AND risk_score <= 100),
    confidence_level DECIMAL(5,2) NOT NULL CHECK (confidence_level >= 0 AND confidence_level <= 100),
    detection_timestamp TIMESTAMPTZ NOT NULL,
    false_positive_probability DECIMAL(5,2) DEFAULT 0,
    assigned_to UUID REFERENCES users(user_id),
    resolution_notes TEXT,
    resolved_at TIMESTAMPTZ,
    resolved_by UUID REFERENCES users(user_id),
    escalated_at TIMESTAMPTZ,
    escalated_to UUID REFERENCES users(user_id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    CONSTRAINT chk_risk_score CHECK (risk_score BETWEEN 0 AND 100),
    CONSTRAINT chk_confidence_level CHECK (confidence_level BETWEEN 0 AND 100)
);

-- Alert investigation workflow
CREATE TABLE alert_investigations (
    investigation_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    alert_id UUID NOT NULL REFERENCES surveillance_alerts(alert_id) ON DELETE CASCADE,
    investigator_id UUID NOT NULL REFERENCES users(user_id),
    status VARCHAR(50) DEFAULT 'IN_PROGRESS',
    priority VARCHAR(20) DEFAULT 'MEDIUM',
    findings TEXT,
    recommendations TEXT,
    supporting_documents JSONB DEFAULT '[]',
    started_at TIMESTAMPTZ DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ===========================================
-- COMPLIANCE & REPORTING
-- ===========================================

-- Regulatory reports
CREATE TABLE regulatory_reports (
    report_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    report_type VARCHAR(100) NOT NULL,
    report_period_start DATE NOT NULL,
    report_period_end DATE NOT NULL,
    status VARCHAR(50) DEFAULT 'PENDING',
    generated_by UUID REFERENCES users(user_id),
    generated_at TIMESTAMPTZ,
    submitted_at TIMESTAMPTZ,
    submission_reference VARCHAR(100),
    report_data JSONB NOT NULL,
    file_path TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Compliance violations
CREATE TABLE compliance_violations (
    violation_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    alert_id UUID REFERENCES surveillance_alerts(alert_id),
    violation_type VARCHAR(100) NOT NULL,
    severity alert_severity NOT NULL,
    description TEXT NOT NULL,
    regulatory_reference VARCHAR(100),
    penalty_amount DECIMAL(15,2) DEFAULT 0,
    status VARCHAR(50) DEFAULT 'OPEN',
    reported_to_regulator BOOLEAN DEFAULT FALSE,
    reported_at TIMESTAMPTZ,
    resolution_notes TEXT,
    resolved_at TIMESTAMPTZ,
    resolved_by UUID REFERENCES users(user_id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ===========================================
-- AUDIT & LOGGING
-- ===========================================

-- Comprehensive audit trail
CREATE TABLE audit_logs (
    log_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    user_id UUID REFERENCES users(user_id),
    session_id UUID REFERENCES user_sessions(session_id),
    action VARCHAR(100) NOT NULL,
    resource_type VARCHAR(50) NOT NULL,
    resource_id UUID,
    old_values JSONB,
    new_values JSONB,
    ip_address INET,
    user_agent TEXT,
    request_id UUID,
    api_endpoint VARCHAR(255),
    http_method VARCHAR(10),
    response_status INTEGER,
    execution_time_ms INTEGER,
    timestamp TIMESTAMPTZ DEFAULT NOW(),
    
    CONSTRAINT chk_http_method CHECK (http_method IN ('GET', 'POST', 'PUT', 'PATCH', 'DELETE'))
);

-- System events log
CREATE TABLE system_events (
    event_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    event_type VARCHAR(100) NOT NULL,
    severity VARCHAR(20) NOT NULL,
    source_system VARCHAR(50) NOT NULL,
    message TEXT NOT NULL,
    details JSONB DEFAULT '{}',
    correlation_id UUID,
    timestamp TIMESTAMPTZ DEFAULT NOW(),
    
    CONSTRAINT chk_severity CHECK (severity IN ('DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL'))
);

-- ===========================================
-- PERFORMANCE INDEXES
-- ===========================================

-- Tenant-based partitioning indexes
CREATE INDEX idx_trades_tenant_time ON trades(tenant_id, trade_time DESC);
CREATE INDEX idx_trades_instrument_time ON trades(instrument_id, trade_time DESC);
CREATE INDEX idx_trades_account_time ON trades(account_id, trade_time DESC);

-- Alert system indexes
CREATE INDEX idx_alerts_tenant_status ON surveillance_alerts(tenant_id, status) WHERE status IN ('OPEN', 'INVESTIGATING');
CREATE INDEX idx_alerts_severity_time ON surveillance_alerts(severity, detection_timestamp DESC);
CREATE INDEX idx_alerts_assigned ON surveillance_alerts(assigned_to) WHERE assigned_to IS NOT NULL;

-- User management indexes
CREATE INDEX idx_users_tenant_active ON users(tenant_id, is_active) WHERE is_active = TRUE;
CREATE INDEX idx_users_email_lower ON users(tenant_id, lower(email));
CREATE INDEX idx_sessions_user_active ON user_sessions(user_id, is_active) WHERE is_active = TRUE;

-- Audit trail indexes
CREATE INDEX idx_audit_logs_tenant_timestamp ON audit_logs(tenant_id, timestamp DESC);
CREATE INDEX idx_audit_logs_user_timestamp ON audit_logs(user_id, timestamp DESC) WHERE user_id IS NOT NULL;
CREATE INDEX idx_audit_logs_resource ON audit_logs(resource_type, resource_id);

-- Full-text search indexes
CREATE INDEX idx_alerts_description_fts ON surveillance_alerts USING GIN(to_tsvector('english', description));
CREATE INDEX idx_instruments_symbol_trgm ON instruments USING GIN(symbol gin_trgm_ops);

-- ===========================================
-- FUNCTIONS AND TRIGGERS
-- ===========================================

-- Function to update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Function to validate trade data
CREATE OR REPLACE FUNCTION validate_trade_data()
RETURNS TRIGGER AS $$
BEGIN
    -- Calculate value if not provided
    IF NEW.value IS NULL THEN
        NEW.value = NEW.quantity * NEW.price;
    END IF;
    
    -- Calculate net amount
    NEW.net_amount = NEW.value + COALESCE(NEW.brokerage, 0) + COALESCE(NEW.taxes, 0);
    
    -- Validate trade time is not in future
    IF NEW.trade_time > NOW() THEN
        RAISE EXCEPTION 'Trade time cannot be in the future';
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Function to auto-assign alerts based on severity
CREATE OR REPLACE FUNCTION auto_assign_alert()
RETURNS TRIGGER AS $$
DECLARE
    compliance_officer_id UUID;
BEGIN
    -- Auto-assign critical alerts to a compliance officer
    IF NEW.severity = 'CRITICAL' AND NEW.assigned_to IS NULL THEN
        SELECT user_id INTO compliance_officer_id
        FROM users
        WHERE tenant_id = NEW.tenant_id
          AND role = 'COMPLIANCE_OFFICER'
          AND is_active = TRUE
        ORDER BY last_login_at DESC
        LIMIT 1;
        
        IF compliance_officer_id IS NOT NULL THEN
            NEW.assigned_to = compliance_officer_id;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ===========================================
-- TRIGGERS
-- ===========================================

-- Updated_at triggers
CREATE TRIGGER update_tenants_updated_at
    BEFORE UPDATE ON tenants
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_trading_accounts_updated_at
    BEFORE UPDATE ON trading_accounts
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_instruments_updated_at
    BEFORE UPDATE ON instruments
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_surveillance_alerts_updated_at
    BEFORE UPDATE ON surveillance_alerts
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Business logic triggers
CREATE TRIGGER validate_trade_trigger
    BEFORE INSERT OR UPDATE ON trades
    FOR EACH ROW
    EXECUTE FUNCTION validate_trade_data();

CREATE TRIGGER auto_assign_alert_trigger
    BEFORE INSERT ON surveillance_alerts
    FOR EACH ROW
    EXECUTE FUNCTION auto_assign_alert();

-- ===========================================
-- ROW LEVEL SECURITY (RLS)
-- ===========================================

-- Enable RLS on tenant-specific tables
ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE trading_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE trades ENABLE ROW LEVEL SECURITY;
ALTER TABLE surveillance_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;

-- RLS Policies (examples - would be fully implemented based on application context)
CREATE POLICY tenant_isolation_policy ON trades
    FOR ALL TO application_role
    USING (tenant_id = current_setting('app.current_tenant_id')::UUID);

-- ===========================================
-- INITIAL DATA
-- ===========================================

-- Insert default surveillance patterns
INSERT INTO surveillance_patterns (pattern_name, description, algorithm_type, parameters, threshold_config) VALUES
('pump_and_dump', 'Detects pump and dump manipulation patterns', 'STATISTICAL_ANALYSIS', 
 '{"lookback_window": "5m", "price_spike_threshold": 15, "volume_spike_threshold": 300}',
 '{"min_price_increase": 10, "min_volume_ratio": 5, "confidence_threshold": 0.85}'),
 
('layering', 'Identifies layering/spoofing in order book', 'ORDER_BOOK_ANALYSIS',
 '{"order_ratio_threshold": 10, "cancellation_rate_threshold": 0.9}',
 '{"min_order_count": 5, "max_execution_ratio": 0.1}'),
 
('wash_trading', 'Detects wash trading between related accounts', 'NETWORK_ANALYSIS',
 '{"time_window": "1h", "price_tolerance": 0.01}',
 '{"min_trade_count": 3, "min_similarity_score": 0.9}'),
 
('insider_trading', 'Identifies potential insider trading patterns', 'TEMPORAL_ANALYSIS',
 '{"event_window": "2d", "abnormal_volume_threshold": 200}',
 '{"min_abnormal_return": 5, "min_confidence": 0.8}'),
 
('front_running', 'Detects front-running of large orders', 'SEQUENCE_ANALYSIS',
 '{"time_threshold": "30s", "size_threshold": 1000000}',
 '{"min_correlation": 0.7, "max_time_gap": 30}');

-- Create application role for RLS
CREATE ROLE application_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO application_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO application_role;

-- Performance optimization: Create materialized view for dashboard metrics
CREATE MATERIALIZED VIEW daily_trading_summary AS
SELECT 
    tenant_id,
    DATE(trade_time) as trade_date,
    COUNT(*) as total_trades,
    SUM(value) as total_value,
    COUNT(DISTINCT account_id) as active_accounts,
    COUNT(DISTINCT instrument_id) as instruments_traded,
    AVG(value) as avg_trade_value
FROM trades
GROUP BY tenant_id, DATE(trade_time);

CREATE UNIQUE INDEX ON daily_trading_summary (tenant_id, trade_date);

-- Comments for documentation
COMMENT ON TABLE tenants IS 'Multi-tenant isolation and subscription management';
COMMENT ON TABLE trades IS 'Core trade records with comprehensive surveillance data';
COMMENT ON TABLE surveillance_alerts IS 'Real-time alerts from pattern detection algorithms';
COMMENT ON TABLE audit_logs IS 'Complete audit trail for compliance and security';
COMMENT ON MATERIALIZED VIEW daily_trading_summary IS 'Pre-computed daily metrics for dashboard performance';
