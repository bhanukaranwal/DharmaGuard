//! DharmaGuard Compliance Service
//! Handles regulatory compliance, SEBI reporting, and violation management

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::Json,
    routing::{get, post, patch},
    Router,
};
use serde::{Deserialize, Serialize};
use sqlx::{PgPool, postgres::PgPoolOptions};
use std::sync::Arc;
use tokio::net::TcpListener;
use tracing::{info, error};
use uuid::Uuid;

#[derive(Clone)]
pub struct AppState {
    pub db: PgPool,
    pub sebi_client: SebiClient,
}

#[derive(Serialize, Deserialize)]
pub struct ComplianceReport {
    pub report_id: Uuid,
    pub report_type: String,
    pub period_start: chrono::NaiveDate,
    pub period_end: chrono::NaiveDate,
    pub status: String,
    pub generated_at: Option<chrono::DateTime<chrono::Utc>>,
    pub submitted_at: Option<chrono::DateTime<chrono::Utc>>,
    pub sebi_reference: Option<String>,
}

#[derive(Serialize, Deserialize)]
pub struct GenerateReportRequest {
    pub report_type: String,
    pub period_start: chrono::NaiveDate,
    pub period_end: chrono::NaiveDate,
    pub tenant_id: Uuid,
}

#[derive(Clone)]
pub struct SebiClient {
    client: reqwest::Client,
    api_key: String,
    base_url: String,
}

impl SebiClient {
    pub fn new(api_key: String) -> Self {
        Self {
            client: reqwest::Client::new(),
            api_key,
            base_url: "https://unified.sebi.gov.in/api/v1".to_string(),
        }
    }

    pub async fn submit_report(&self, report: &ComplianceReport) -> anyhow::Result<String> {
        let response = self.client
            .post(&format!("{}/reports", self.base_url))
            .header("Authorization", &format!("Bearer {}", self.api_key))
            .json(report)
            .send()
            .await?;

        if response.status().is_success() {
            let result: serde_json::Value = response.json().await?;
            Ok(result["reference_id"].as_str().unwrap_or("").to_string())
        } else {
            Err(anyhow::anyhow!("Failed to submit report to SEBI"))
        }
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt::init();

    let database_url = std::env::var("DATABASE_URL")
        .expect("DATABASE_URL must be set");
    
    let sebi_api_key = std::env::var("SEBI_API_KEY")
        .expect("SEBI_API_KEY must be set");

    let pool = PgPoolOptions::new()
        .max_connections(20)
        .connect(&database_url)
        .await?;

    let sebi_client = SebiClient::new(sebi_api_key);

    let app_state = AppState {
        db: pool,
        sebi_client,
    };

    let app = Router::new()
        .route("/health", get(health_check))
        .route("/reports", post(generate_report).get(list_reports))
        .route("/reports/:id", get(get_report))
        .route("/reports/:id/submit", post(submit_report))
        .route("/violations", get(list_violations))
        .with_state(app_state);

    let listener = TcpListener::bind("0.0.0.0:8082").await?;
    info!("Compliance service listening on port 8082");
    
    axum::serve(listener, app).await?;
    Ok(())
}

async fn health_check() -> Json<serde_json::Value> {
    Json(serde_json::json!({"status": "healthy", "service": "compliance"}))
}

async fn generate_report(
    State(state): State<AppState>,
    Json(request): Json<GenerateReportRequest>,
) -> Result<Json<ComplianceReport>, StatusCode> {
    let report_id = Uuid::new_v4();
    
    // Generate report based on type
    let report = match generate_report_data(&state.db, &request).await {
        Ok(data) => ComplianceReport {
            report_id,
            report_type: request.report_type,
            period_start: request.period_start,
            period_end: request.period_end,
            status: "GENERATED".to_string(),
            generated_at: Some(chrono::Utc::now()),
            submitted_at: None,
            sebi_reference: None,
        },
        Err(_) => return Err(StatusCode::INTERNAL_SERVER_ERROR),
    };

    // Store in database
    match sqlx::query!(
        r#"
        INSERT INTO regulatory_reports_v2 (report_id, template_id, report_period_start, report_period_end, status, generated_at)
        VALUES ($1, $2, $3, $4, $5, $6)
        "#,
        report.report_id,
        Uuid::new_v4(), // template_id placeholder
        report.period_start,
        report.period_end,
        report.status,
        report.generated_at
    )
    .execute(&state.db)
    .await {
        Ok(_) => Ok(Json(report)),
        Err(_) => Err(StatusCode::INTERNAL_SERVER_ERROR),
    }
}

async fn submit_report(
    Path(report_id): Path<Uuid>,
    State(state): State<AppState>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    // Get report from database
    let report = match sqlx::query_as!(
        ComplianceReport,
        "SELECT report_id, 'DAILY_SUMMARY' as report_type, report_period_start::date as period_start, report_period_end::date as period_end, status, generated_at, submitted_at, acknowledgment_reference as sebi_reference FROM regulatory_reports_v2 WHERE report_id = $1",
        report_id
    )
    .fetch_one(&state.db)
    .await {
        Ok(report) => report,
        Err(_) => return Err(StatusCode::NOT_FOUND),
    };

    // Submit to SEBI
    match state.sebi_client.submit_report(&report).await {
        Ok(reference) => {
            // Update database with submission details
            sqlx::query!(
                "UPDATE regulatory_reports_v2 SET status = 'SUBMITTED', submitted_at = $1, acknowledgment_reference = $2 WHERE report_id = $3",
                chrono::Utc::now(),
                reference,
                report_id
            )
            .execute(&state.db)
            .await
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

            Ok(Json(serde_json::json!({
                "status": "submitted",
                "sebi_reference": reference
            })))
        },
        Err(_) => Err(StatusCode::INTERNAL_SERVER_ERROR),
    }
}

async fn list_reports(State(state): State<AppState>) -> Result<Json<Vec<ComplianceReport>>, StatusCode> {
    match sqlx::query_as!(
        ComplianceReport,
        "SELECT report_id, 'DAILY_SUMMARY' as report_type, report_period_start::date as period_start, report_period_end::date as period_end, status, generated_at, submitted_at, acknowledgment_reference as sebi_reference FROM regulatory_reports_v2 ORDER BY generated_at DESC LIMIT 50"
    )
    .fetch_all(&state.db)
    .await {
        Ok(reports) => Ok(Json(reports)),
        Err(_) => Err(StatusCode::INTERNAL_SERVER_ERROR),
    }
}

async fn get_report(
    Path(report_id): Path<Uuid>,
    State(state): State<AppState>,
) -> Result<Json<ComplianceReport>, StatusCode> {
    match sqlx::query_as!(
        ComplianceReport,
        "SELECT report_id, 'DAILY_SUMMARY' as report_type, report_period_start::date as period_start, report_period_end::date as period_end, status, generated_at, submitted_at, acknowledgment_reference as sebi_reference FROM regulatory_reports_v2 WHERE report_id = $1",
        report_id
    )
    .fetch_one(&state.db)
    .await {
        Ok(report) => Ok(Json(report)),
        Err(_) => Err(StatusCode::NOT_FOUND),
    }
}

async fn list_violations(State(state): State<AppState>) -> Result<Json<Vec<serde_json::Value>>, StatusCode> {
    match sqlx::query!(
        "SELECT violation_id, violation_type, severity, description FROM compliance_violations ORDER BY created_at DESC LIMIT 50"
    )
    .fetch_all(&state.db)
    .await {
        Ok(violations) => {
            let result: Vec<serde_json::Value> = violations.into_iter().map(|v| {
                serde_json::json!({
                    "violation_id": v.violation_id,
                    "violation_type": v.violation_type,
                    "severity": v.severity,
                    "description": v.description
                })
            }).collect();
            Ok(Json(result))
        },
        Err(_) => Err(StatusCode::INTERNAL_SERVER_ERROR),
    }
}

async fn generate_report_data(
    db: &PgPool,
    request: &GenerateReportRequest,
) -> anyhow::Result<serde_json::Value> {
    // Generate report data based on type
    match request.report_type.as_str() {
        "DAILY_TRADING_SUMMARY" => {
            let trade_data = sqlx::query!(
                "SELECT COUNT(*) as trade_count, SUM(value) as total_value FROM trades WHERE tenant_id = $1 AND DATE(trade_time) BETWEEN $2 AND $3",
                request.tenant_id,
                request.period_start,
                request.period_end
            )
            .fetch_one(db)
            .await?;

            Ok(serde_json::json!({
                "trade_count": trade_data.trade_count,
                "total_value": trade_data.total_value,
                "period": format!("{} to {}", request.period_start, request.period_end)
            }))
        },
        _ => Ok(serde_json::json!({"message": "Report generated"}))
    }
}
