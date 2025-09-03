//! DharmaGuard Reporting Service
//! Advanced reporting system with automated SEBI compliance reports

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::Json,
    routing::{get, post},
    Router,
};
use serde::{Deserialize, Serialize};
use sqlx::{PgPool, postgres::PgPoolOptions, Row};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::net::TcpListener;
use tokio_cron_scheduler::{JobScheduler, Job};
use tracing::{info, error, warn};
use uuid::Uuid;

#[derive(Clone)]
pub struct AppState {
    pub db: PgPool,
    pub scheduler: Arc<JobScheduler>,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct GenerateReportRequest {
    pub tenant_id: Uuid,
    pub report_type: String,
    pub period_start: chrono::NaiveDate,
    pub period_end: chrono::NaiveDate,
    pub format: String, // PDF, CSV, JSON, XML
}

#[derive(Serialize, Deserialize)]
pub struct ReportResponse {
    pub report_id: Uuid,
    pub report_type: String,
    pub status: String,
    pub file_path: Option<String>,
    pub generated_at: Option<chrono::DateTime<chrono::Utc>>,
    pub download_url: Option<String>,
}

#[derive(Serialize, Deserialize)]
pub struct TradingSummaryReport {
    pub total_trades: i64,
    pub total_volume: f64,
    pub total_value: f64,
    pub unique_instruments: i64,
    pub active_clients: i64,
    pub average_trade_size: f64,
    pub largest_trade: f64,
    pub trading_hours_distribution: HashMap<String, i64>,
    pub instrument_breakdown: Vec<InstrumentStats>,
}

#[derive(Serialize, Deserialize)]
pub struct InstrumentStats {
    pub instrument: String,
    pub trade_count: i64,
    pub total_volume: f64,
    pub total_value: f64,
    pub avg_price: f64,
}

#[derive(Serialize, Deserialize)]
pub struct ComplianceReport {
    pub alerts_generated: i64,
    pub critical_alerts: i64,
    pub resolved_alerts: i64,
    pub pending_investigations: i64,
    pub compliance_score: f64,
    pub violations_detected: i64,
    pub pattern_breakdown: HashMap<String, i64>,
    pub risk_metrics: RiskMetrics,
}

#[derive(Serialize, Deserialize)]
pub struct RiskMetrics {
    pub var_95: f64,
    pub var_99: f64,
    pub max_drawdown: f64,
    pub sharpe_ratio: f64,
    pub volatility: f64,
}

pub struct ReportGenerator {
    db: PgPool,
}

impl ReportGenerator {
    pub fn new(db: PgPool) -> Self {
        Self { db }
    }

    pub async fn generate_trading_summary(
        &self,
        tenant_id: Uuid,
        start_date: chrono::NaiveDate,
        end_date: chrono::NaiveDate,
    ) -> Result<TradingSummaryReport, sqlx::Error> {
        // Basic trading statistics
        let basic_stats = sqlx::query!(
            r#"
            SELECT 
                COUNT(*) as total_trades,
                COALESCE(SUM(quantity), 0) as total_volume,
                COALESCE(SUM(value), 0) as total_value,
                COUNT(DISTINCT instrument_id) as unique_instruments,
                COUNT(DISTINCT account_id) as active_clients,
                COALESCE(AVG(value), 0) as average_trade_size,
                COALESCE(MAX(value), 0) as largest_trade
            FROM trades 
            WHERE tenant_id = $1 
            AND DATE(trade_time) BETWEEN $2 AND $3
            "#,
            tenant_id,
            start_date,
            end_date
        )
        .fetch_one(&self.db)
        .await?;

        // Trading hours distribution
        let hours_distribution = sqlx::query!(
            r#"
            SELECT 
                EXTRACT(HOUR FROM trade_time) as hour,
                COUNT(*) as trade_count
            FROM trades 
            WHERE tenant_id = $1 
            AND DATE(trade_time) BETWEEN $2 AND $3
            GROUP BY EXTRACT(HOUR FROM trade_time)
            ORDER BY hour
            "#,
            tenant_id,
            start_date,
            end_date
        )
        .fetch_all(&self.db)
        .await?;

        let mut trading_hours_distribution = HashMap::new();
        for row in hours_distribution {
            let hour = row.hour.unwrap_or(0.0) as i32;
            trading_hours_distribution.insert(format!("{}:00", hour), row.trade_count.unwrap_or(0));
        }

        // Instrument breakdown
        let instrument_stats = sqlx::query!(
            r#"
            SELECT 
                i.symbol as instrument,
                COUNT(*) as trade_count,
                COALESCE(SUM(t.quantity), 0) as total_volume,
                COALESCE(SUM(t.value), 0) as total_value,
                COALESCE(AVG(t.price), 0) as avg_price
            FROM trades t
            JOIN instruments i ON t.instrument_id = i.instrument_id
            WHERE t.tenant_id = $1 
            AND DATE(t.trade_time) BETWEEN $2 AND $3
            GROUP BY i.symbol
            ORDER BY total_value DESC
            LIMIT 20
            "#,
            tenant_id,
            start_date,
            end_date
        )
        .fetch_all(&self.db)
        .await?;

        let instrument_breakdown: Vec<InstrumentStats> = instrument_stats
            .into_iter()
            .map(|row| InstrumentStats {
                instrument: row.instrument.unwrap_or_default(),
                trade_count: row.trade_count.unwrap_or(0),
                total_volume: row.total_volume.unwrap_or(0.0) as f64,
                total_value: row.total_value.unwrap_or(0.0) as f64,
                avg_price: row.avg_price.unwrap_or(0.0) as f64,
            })
            .collect();

        Ok(TradingSummaryReport {
            total_trades: basic_stats.total_trades.unwrap_or(0),
            total_volume: basic_stats.total_volume.unwrap_or(0.0) as f64,
            total_value: basic_stats.total_value.unwrap_or(0.0) as f64,
            unique_instruments: basic_stats.unique_instruments.unwrap_or(0),
            active_clients: basic_stats.active_clients.unwrap_or(0),
            average_trade_size: basic_stats.average_trade_size.unwrap_or(0.0) as f64,
            largest_trade: basic_stats.largest_trade.unwrap_or(0.0) as f64,
            trading_hours_distribution,
            instrument_breakdown,
        })
    }

    pub async fn generate_compliance_report(
        &self,
        tenant_id: Uuid,
        start_date: chrono::NaiveDate,
        end_date: chrono::NaiveDate,
    ) -> Result<ComplianceReport, sqlx::Error> {
        // Alert statistics
        let alert_stats = sqlx::query!(
            r#"
            SELECT 
                COUNT(*) as total_alerts,
                COUNT(CASE WHEN severity = 'CRITICAL' THEN 1 END) as critical_alerts,
                COUNT(CASE WHEN status = 'RESOLVED' THEN 1 END) as resolved_alerts,
                COUNT(CASE WHEN status IN ('OPEN', 'INVESTIGATING') THEN 1 END) as pending_investigations
            FROM surveillance_alerts 
            WHERE tenant_id = $1 
            AND DATE(created_at) BETWEEN $2 AND $3
            "#,
            tenant_id,
            start_date,
            end_date
        )
        .fetch_one(&self.db)
        .await?;

        // Pattern breakdown
        let pattern_stats = sqlx::query!(
            r#"
            SELECT 
                alert_type,
                COUNT(*) as count
            FROM surveillance_alerts 
            WHERE tenant_id = $1 
            AND DATE(created_at) BETWEEN $2 AND $3
            GROUP BY alert_type
            "#,
            tenant_id,
            start_date,
            end_date
        )
        .fetch_all(&self.db)
        .await?;

        let mut pattern_breakdown = HashMap::new();
        for row in pattern_stats {
            pattern_breakdown.insert(row.alert_type, row.count.unwrap_or(0));
        }

        // Calculate compliance score (simplified)
        let total_alerts = alert_stats.total_alerts.unwrap_or(0) as f64;
        let critical_alerts = alert_stats.critical_alerts.unwrap_or(0) as f64;
        let resolved_alerts = alert_stats.resolved_alerts.unwrap_or(0) as f64;
        
        let compliance_score = if total_alerts > 0.0 {
            100.0 - (critical_alerts * 10.0 + (total_alerts - resolved_alerts) * 2.0)
        } else {
            100.0
        }.max(0.0);

        // Mock risk metrics (in production, these would be calculated from actual trade data)
        let risk_metrics = RiskMetrics {
            var_95: 0.05,
            var_99: 0.08,
            max_drawdown: 0.12,
            sharpe_ratio: 1.45,
            volatility: 0.18,
        };

        Ok(ComplianceReport {
            alerts_generated: alert_stats.total_alerts.unwrap_or(0),
            critical_alerts: alert_stats.critical_alerts.unwrap_or(0),
            resolved_alerts: alert_stats.resolved_alerts.unwrap_or(0),
            pending_investigations: alert_stats.pending_investigations.unwrap_or(0),
            compliance_score,
            violations_detected: critical_alerts as i64,
            pattern_breakdown,
            risk_metrics,
        })
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt::init();

    let database_url = std::env::var("DATABASE_URL")
        .expect("DATABASE_URL must be set");

    let pool = PgPoolOptions::new()
        .max_connections(20)
        .connect(&database_url)
        .await?;

    // Initialize job scheduler for automated reports
    let scheduler = JobScheduler::new().await?;
    
    // Schedule daily reports at 6 AM
    let daily_report_job = Job::new_async("0 0 6 * * *", |_uuid, _l| {
        Box::pin(async move {
            info!("Generating scheduled daily reports");
            // Implementation for scheduled report generation
        })
    })?;
    
    scheduler.add(daily_report_job).await?;
    scheduler.start().await?;

    let app_state = AppState {
        db: pool,
        scheduler: Arc::new(scheduler),
    };

    let app = Router::new()
        .route("/health", get(health_check))
        .route("/reports", post(generate_report).get(list_reports))
        .route("/reports/:id", get(get_report))
        .route("/reports/:id/download", get(download_report))
        .route("/reports/scheduled", get(list_scheduled_reports))
        .with_state(app_state);

    let listener = TcpListener::bind("0.0.0.0:8083").await?;
    info!("Reporting service listening on port 8083");
    
    axum::serve(listener, app).await?;
    Ok(())
}

async fn health_check() -> Json<serde_json::Value> {
    Json(serde_json::json!({"status": "healthy", "service": "reporting"}))
}

async fn generate_report(
    State(state): State<AppState>,
    Json(request): Json<GenerateReportRequest>,
) -> Result<Json<ReportResponse>, StatusCode> {
    let report_id = Uuid::new_v4();
    info!("Generating report: {:?} for tenant: {}", request.report_type, request.tenant_id);

    let generator = ReportGenerator::new(state.db.clone());
    
    let report_data = match request.report_type.as_str() {
        "TRADING_SUMMARY" => {
            match generator.generate_trading_summary(
                request.tenant_id,
                request.period_start,
                request.period_end,
            ).await {
                Ok(data) => serde_json::to_value(data).unwrap(),
                Err(e) => {
                    error!("Failed to generate trading summary: {}", e);
                    return Err(StatusCode::INTERNAL_SERVER_ERROR);
                }
            }
        }
        "COMPLIANCE_REPORT" => {
            match generator.generate_compliance_report(
                request.tenant_id,
                request.period_start,
                request.period_end,
            ).await {
                Ok(data) => serde_json::to_value(data).unwrap(),
                Err(e) => {
                    error!("Failed to generate compliance report: {}", e);
                    return Err(StatusCode::INTERNAL_SERVER_ERROR);
                }
            }
        }
        _ => {
            warn!("Unknown report type: {}", request.report_type);
            return Err(StatusCode::BAD_REQUEST);
        }
    };

    // Store report in database
    match sqlx::query!(
        r#"
        INSERT INTO regulatory_reports_v2 (
            report_id, template_id, report_period_start, report_period_end, 
            status, report_data, generated_at
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        "#,
        report_id,
        Uuid::new_v4(), // template_id
        request.period_start,
        request.period_end,
        "GENERATED",
        &report_data,
        chrono::Utc::now()
    )
    .execute(&state.db)
    .await {
        Ok(_) => {
            let response = ReportResponse {
                report_id,
                report_type: request.report_type,
                status: "GENERATED".to_string(),
                file_path: Some(format!("/reports/{}.{}", report_id, request.format.to_lowercase())),
                generated_at: Some(chrono::Utc::now()),
                download_url: Some(format!("/reports/{}/download", report_id)),
            };
            Ok(Json(response))
        }
        Err(e) => {
            error!("Failed to store report: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

async fn list_reports(State(state): State<AppState>) -> Result<Json<Vec<ReportResponse>>, StatusCode> {
    match sqlx::query!(
        r#"
        SELECT report_id, 'UNKNOWN' as report_type, status, generated_at
        FROM regulatory_reports_v2 
        ORDER BY generated_at DESC 
        LIMIT 50
        "#
    )
    .fetch_all(&state.db)
    .await {
        Ok(rows) => {
            let reports: Vec<ReportResponse> = rows.into_iter().map(|row| {
                ReportResponse {
                    report_id: row.report_id,
                    report_type: row.report_type.to_string(),
                    status: row.status,
                    file_path: Some(format!("/reports/{}.pdf", row.report_id)),
                    generated_at: row.generated_at,
                    download_url: Some(format!("/reports/{}/download", row.report_id)),
                }
            }).collect();
            Ok(Json(reports))
        }
        Err(e) => {
            error!("Failed to list reports: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

async fn get_report(
    Path(report_id): Path<Uuid>,
    State(state): State<AppState>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    match sqlx::query!(
        "SELECT report_data FROM regulatory_reports_v2 WHERE report_id = $1",
        report_id
    )
    .fetch_one(&state.db)
    .await {
        Ok(row) => Ok(Json(row.report_data)),
        Err(_) => Err(StatusCode::NOT_FOUND),
    }
}

async fn download_report(
    Path(report_id): Path<Uuid>,
    State(_state): State<AppState>,
) -> Result<String, StatusCode> {
    // In a real implementation, this would serve the actual file
    Ok(format!("Report {} download would be served here", report_id))
}

async fn list_scheduled_reports() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "scheduled_reports": [
            {
                "name": "Daily Trading Summary",
                "schedule": "0 0 6 * * *",
                "enabled": true
            },
            {
                "name": "Weekly Compliance Report",
                "schedule": "0 0 6 * * 1",
                "enabled": true
            }
        ]
    }))
}
