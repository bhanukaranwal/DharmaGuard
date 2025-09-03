-- Migration: Enhanced Compliance Schema
-- Version: 1.1.0
-- Description: Advanced compliance features and regulatory reporting

-- ===========================================
-- REGULATORY FRAMEWORK
-- ===========================================

-- Regulatory frameworks and rules
CREATE TABLE regulatory_frameworks (
    framework_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(100) NOT NULL UNIQUE,
    regulator VARCHAR(50) NOT NULL,
    jurisdiction VARCHAR(50) NOT NULL,
    version VARCHAR(20) NOT NULL,
    effective_date DATE NOT NULL,
    description TEXT,
    rules_document_url TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Specific regulatory rules
CREATE TABLE regulatory_rules (
    rule_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    framework_id UUID NOT NULL REFERENCES regulatory_frameworks(framework_id) ON DELETE CASCADE,
    rule_number VARCHAR(50) NOT NULL,
    title VARCHAR(255) NOT NULL,
    description TEXT NOT NULL,
    rule_type VARCHAR(50) NOT NULL, -- PROHIBITION, DISCLOSURE, REPORTING, etc.
    severity alert_severity NOT NULL,
    penalty_description TEXT,
    parameters JSONB DEFAULT '{}',
    monitoring_required BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    UNIQUE(framework_id, rule_number)
);

-- ===========================================
-- CLIENT MANAGEMENT
-- ===========================================

-- Enhanced client profiles for KYC/AML
CREATE TABLE clients (
    client_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    client_code VARCHAR(50) NOT NULL,
    client_type VARCHAR(20) NOT NULL, -- INDIVIDUAL, CORPORATE, PARTNERSHIP, etc.
    name VARCHAR(255) NOT NULL,
    pan VARCHAR(10),
    aadhaar VARCHAR(12),
    date_of_birth DATE,
    phone VARCHAR(20),
    email VARCHAR(255),
    address JSONB NOT NULL,
    kyc_status VARCHAR(20) DEFAULT 'PENDING',
    kyc_completed_at TIMESTAMPTZ,
    risk_category VARCHAR(20) DEFAULT 'LOW', -- LOW, MEDIUM, HIGH
    pep_status BOOLEAN DEFAULT FALSE, -- Politically Exposed Person
    sanctions_checked BOOLEAN DEFAULT FALSE,
    annual_income_range VARCHAR(50),
    net_worth_range VARCHAR(50),
    occupation VARCHAR(100),
    bank_details JSONB DEFAULT '{}',
    demat_account VARCHAR(20),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    CONSTRAINT unique_client_code_per_tenant UNIQUE (tenant_id, client_code),
    CONSTRAINT chk_pan_format CHECK (pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]{1}$'),
    CONSTRAINT chk_client_type CHECK (client_type IN ('INDIVIDUAL', 'CORPORATE', 'PARTNERSHIP', 'TRUST', 'HUF')),
    CONSTRAINT chk_kyc_status CHECK (kyc_status IN ('PENDING', 'IN_PROGRESS', 'COMPLETED', 'REJECTED', 'EXPIRED')),
    CONSTRAINT chk_risk_category CHECK (risk_category IN ('LOW', 'MEDIUM', 'HIGH'))
);

-- Client document management
CREATE TABLE client_documents (
    document_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    client_id UUID NOT NULL REFERENCES clients(client_id) ON DELETE CASCADE,
    document_type VARCHAR(50) NOT NULL,
    document_number VARCHAR(100),
    file_path TEXT NOT NULL,
    file_hash TEXT NOT NULL,
    uploaded_by UUID REFERENCES users(user_id),
    verification_status VARCHAR(20) DEFAULT 'PENDING',
    verified_by UUID REFERENCES users(user_id),
    verified_at TIMESTAMPTZ,
    expiry_date DATE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    
    CONSTRAINT chk_verification_status CHECK (verification_status IN ('PENDING', 'VERIFIED', 'REJECTED', 'EXPIRED'))
);

-- ===========================================
-- POSITION MANAGEMENT
-- ===========================================

-- Real-time position tracking
CREATE TABLE positions (
    position_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES trading_accounts(account_id),
    instrument_id UUID NOT NULL REFERENCES instruments(instrument_id),
    client_id UUID REFERENCES clients(client_id),
    net_quantity BIGINT NOT NULL DEFAULT 0,
    average_price DECIMAL(20,8) DEFAULT 0,
    market_value DECIMAL(25,8) DEFAULT 0,
    unrealized_pnl DECIMAL(25,8) DEFAULT 0,
    last_trade_price DECIMAL(20,8),
    last_updated TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    
    UNIQUE(account_id, instrument_id)
);

-- Position limits and risk controls
CREATE TABLE position_limits (
    limit_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    account_id UUID REFERENCES trading_accounts(account_id),
    instrument_id UUID REFERENCES instruments(instrument_id),
    client_id UUID REFERENCES clients(client_id),
    limit_type VARCHAR(50) NOT NULL, -- POSITION_LIMIT, TURNOVER_LIMIT, LOSS_LIMIT
    limit_value DECIMAL(25,8) NOT NULL,
    period VARCHAR(20) DEFAULT 'DAILY', -- DAILY, WEEKLY, MONTHLY
    current_utilization DECIMAL(25,8) DEFAULT 0,
    breach_action VARCHAR(50) DEFAULT 'ALERT', -- ALERT, BLOCK, AUTO_SQUARE_OFF
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    CONSTRAINT chk_limit_type CHECK (limit_type IN ('POSITION_LIMIT', 'TURNOVER_LIMIT', 'LOSS_LIMIT', 'EXPOSURE_LIMIT')),
    CONSTRAINT chk_period CHECK (period IN ('INTRADAY', 'DAILY', 'WEEKLY', 'MONTHLY')),
    CONSTRAINT chk_breach_action CHECK (breach_action IN ('ALERT', 'BLOCK', 'AUTO_SQUARE_OFF'))
);

-- ===========================================
-- ENHANCED SURVEILLANCE
-- ===========================================

-- Market manipulation patterns
CREATE TABLE manipulation_patterns (
    pattern_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    pattern_name VARCHAR(100) NOT NULL UNIQUE,
    category VARCHAR(50) NOT NULL, -- PRICE_MANIPULATION, VOLUME_MANIPULATION, etc.
    detection_algorithm JSONB NOT NULL,
    risk_weights JSONB NOT NULL,
    threshold_config JSONB NOT NULL,
    regulatory_reference VARCHAR(100),
    description TEXT NOT NULL,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Surveillance results with enhanced metadata
CREATE TABLE surveillance_results (
    result_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    pattern_id UUID NOT NULL REFERENCES manipulation_patterns(pattern_id),
    scan_timestamp TIMESTAMPTZ NOT NULL,
    time_window_start TIMESTAMPTZ NOT NULL,
    time_window_end TIMESTAMPTZ NOT NULL,
    entities_scanned JSONB NOT NULL, -- accounts, instruments, etc.
    matches_found INTEGER DEFAULT 0,
    alerts_generated INTEGER DEFAULT 0,
    execution_time_ms INTEGER,
    scan_parameters JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Cross-reference for related alerts
CREATE TABLE alert_relationships (
    relationship_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    primary_alert_id UUID NOT NULL REFERENCES surveillance_alerts(alert_id) ON DELETE CASCADE,
    related_alert_id UUID NOT NULL REFERENCES surveillance_alerts(alert_id) ON DELETE CASCADE,
    relationship_type VARCHAR(50) NOT NULL, -- DUPLICATE, RELATED, ESCALATION
    confidence_score DECIMAL(5,2) NOT NULL CHECK (confidence_score BETWEEN 0 AND 100),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    
    CONSTRAINT chk_not_self_reference CHECK (primary_alert_id != related_alert_id),
    UNIQUE(primary_alert_id, related_alert_id)
);

-- ===========================================
-- REPORTING ENHANCEMENTS
-- ===========================================

-- Report templates for standardized reporting
CREATE TABLE report_templates (
    template_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    template_name VARCHAR(100) NOT NULL UNIQUE,
    report_type VARCHAR(50) NOT NULL,
    regulator VARCHAR(50) NOT NULL,
    frequency VARCHAR(20) NOT NULL, -- DAILY, WEEKLY, MONTHLY, QUARTERLY, ANNUAL
    template_structure JSONB NOT NULL,
    validation_rules JSONB DEFAULT '{}',
    submission_deadline_days INTEGER DEFAULT 7,
    is_mandatory BOOLEAN DEFAULT TRUE,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    CONSTRAINT chk_frequency CHECK (frequency IN ('DAILY', 'WEEKLY', 'MONTHLY', 'QUARTERLY', 'ANNUAL', 'ON_DEMAND'))
);

-- Enhanced regulatory reports with validation
CREATE TABLE regulatory_reports_v2 (
    report_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    template_id UUID NOT NULL REFERENCES report_templates(template_id),
    report_period_start DATE NOT NULL,
    report_period_end DATE NOT NULL,
    status VARCHAR(50) DEFAULT 'DRAFT',
    generated_by UUID REFERENCES users(user_id),
    reviewed_by UUID REFERENCES users(user_id),
    approved_by UUID REFERENCES users(user_id),
    generated_at TIMESTAMPTZ,
    reviewed_at TIMESTAMPTZ,
    approved_at TIMESTAMPTZ,
    submitted_at TIMESTAMPTZ,
    submission_reference VARCHAR(100),
    acknowledgment_reference VARCHAR(100),
    report_data JSONB NOT NULL,
    validation_errors JSONB DEFAULT '[]',
    file_path TEXT,
    file_hash TEXT,
    digital_signature TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    CONSTRAINT chk_report_status CHECK (status IN ('DRAFT', 'GENERATED', 'REVIEWED', 'APPROVED', 'SUBMITTED', 'ACKNOWLEDGED', 'REJECTED'))
);

-- ===========================================
-- WHISTLEBLOWER SYSTEM
-- ===========================================

-- Anonymous tip submissions
CREATE TABLE whistleblower_tips (
    tip_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    anonymous_id VARCHAR(50) NOT NULL UNIQUE, -- For anonymous follow-up
    category VARCHAR(50) NOT NULL,
    severity alert_severity NOT NULL,
    subject VARCHAR(255) NOT NULL,
    description TEXT NOT NULL,
    supporting_evidence JSONB DEFAULT '[]',
    status VARCHAR(50) DEFAULT 'SUBMITTED',
    assigned_to UUID REFERENCES users(user_id),
    investigation_notes TEXT,
    resolution VARCHAR(50),
    resolved_at TIMESTAMPTZ,
    resolved_by UUID REFERENCES users(user_id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    CONSTRAINT chk_tip_status CHECK (status IN ('SUBMITTED', 'UNDER_REVIEW', 'INVESTIGATING', 'RESOLVED', 'CLOSED'))
);

-- ===========================================
-- PERFORMANCE INDEXES
-- ===========================================

-- Client management indexes
CREATE INDEX idx_clients_tenant_status ON clients(tenant_id, kyc_status);
CREATE INDEX idx_clients_pan ON clients(pan) WHERE pan IS NOT NULL;
CREATE INDEX idx_clients_risk_category ON clients(tenant_id, risk_category);

-- Position tracking indexes
CREATE INDEX idx_positions_account_instrument ON positions(account_id, instrument_id);
CREATE INDEX idx_positions_client_updated ON positions(client_id, last_updated DESC) WHERE client_id IS NOT NULL;

-- Surveillance indexes
CREATE INDEX idx_surveillance_results_pattern_timestamp ON surveillance_results(pattern_id, scan_timestamp DESC);
CREATE INDEX idx_alert_relationships_primary ON alert_relationships(primary_alert_id);

-- Reporting indexes
CREATE INDEX idx_reports_v2_tenant_period ON regulatory_reports_v2(tenant_id, report_period_start DESC);
CREATE INDEX idx_reports_v2_template_status ON regulatory_reports_v2(template_id, status);

-- ===========================================
-- ADDITIONAL TRIGGERS
-- ===========================================

-- Trigger to update position after trade
CREATE OR REPLACE FUNCTION update_position_after_trade()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO positions (tenant_id, account_id, instrument_id, client_id, net_quantity, average_price, last_updated)
    VALUES (NEW.tenant_id, NEW.account_id, NEW.instrument_id, 
            (SELECT client_id FROM trading_accounts WHERE account_id = NEW.account_id),
            CASE WHEN NEW.trade_type IN ('BUY') THEN NEW.quantity ELSE -NEW.quantity END,
            NEW.price, NEW.trade_time)
    ON CONFLICT (account_id, instrument_id)
    DO UPDATE SET
        net_quantity = positions.net_quantity + 
            CASE WHEN NEW.trade_type IN ('BUY') THEN NEW.quantity ELSE -NEW.quantity END,
        average_price = CASE 
            WHEN (positions.net_quantity + CASE WHEN NEW.trade_type IN ('BUY') THEN NEW.quantity ELSE -NEW.quantity END) = 0 
            THEN 0
            ELSE (positions.average_price * positions.net_quantity + NEW.price * NEW.quantity) / 
                 (positions.net_quantity + CASE WHEN NEW.trade_type IN ('BUY') THEN NEW.quantity ELSE -NEW.quantity END)
        END,
        last_updated = NEW.trade_time;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_position_trigger
    AFTER INSERT ON trades
    FOR EACH ROW
    EXECUTE FUNCTION update_position_after_trade();

-- ===========================================
-- INITIAL COMPLIANCE DATA
-- ===========================================

-- Insert SEBI regulatory framework
INSERT INTO regulatory_frameworks (name, regulator, jurisdiction, version, effective_date, description) VALUES
('SEBI PFUTP Regulations', 'SEBI', 'INDIA', '2.0', '2022-05-01', 'Prevention of Fraudulent and Unfair Trade Practices'),
('SEBI Intermediaries Regulations', 'SEBI', 'INDIA', '1.0', '2021-04-01', 'Stock Brokers and Sub-Brokers Regulations'),
('SEBI Listing Obligations', 'SEBI', 'INDIA', '3.0', '2023-01-01', 'Listing Obligations and Disclosure Requirements');

-- Insert manipulation patterns
INSERT INTO manipulation_patterns (pattern_name, category, detection_algorithm, risk_weights, threshold_config, description) VALUES
('circular_trading', 'PRICE_MANIPULATION', 
 '{"type": "graph_analysis", "min_cycle_length": 3, "max_participants": 10}',
 '{"volume_weight": 0.3, "price_impact_weight": 0.4, "timing_weight": 0.3}',
 '{"min_volume": 100000, "max_time_gap_minutes": 60}',
 'Detects circular trading patterns between related accounts'),
 
('ramping', 'PRICE_MANIPULATION',
 '{"type": "price_movement", "consecutive_trades": 5, "price_direction": "up"}',
 '{"price_momentum_weight": 0.5, "volume_consistency_weight": 0.3, "time_clustering_weight": 0.2}',
 '{"min_price_increase_percent": 5, "max_time_window_minutes": 30}',
 'Identifies artificial price ramping through coordinated buying');

-- Insert default report templates
INSERT INTO report_templates (template_name, report_type, regulator, frequency, template_structure, is_mandatory) VALUES
('Daily Trading Summary', 'TRADING_SUMMARY', 'SEBI', 'DAILY',
 '{"sections": ["trade_summary", "position_summary", "client_summary"], "format": "JSON"}', true),
 
('Monthly Compliance Report', 'COMPLIANCE_SUMMARY', 'SEBI', 'MONTHLY',
 '{"sections": ["surveillance_alerts", "violations", "investigations"], "format": "PDF"}', true),
 
('Suspicious Transaction Report', 'STR', 'SEBI', 'ON_DEMAND',
 '{"sections": ["transaction_details", "suspicious_indicators", "investigation_summary"], "format": "XML"}', true);

COMMENT ON TABLE clients IS 'Enhanced client profiles with KYC/AML compliance features';
COMMENT ON TABLE positions IS 'Real-time position tracking for risk management';
COMMENT ON TABLE manipulation_patterns IS 'Advanced market manipulation detection patterns';
COMMENT ON TABLE regulatory_reports_v2 IS 'Enhanced regulatory reporting with approval workflow';
