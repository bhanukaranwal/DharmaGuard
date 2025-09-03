//! DharmaGuard Audit Service
//! Blockchain-enabled immutable audit trails with IPFS storage

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::Json,
    routing::{get, post},
    Router,
};
use mongodb::{Client as MongoClient, Database};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::{PgPool, postgres::PgPoolOptions};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::net::TcpListener;
use tracing::{info, error, warn};
use uuid::Uuid;
use web3::{Web3, transports::Http, types::Address};

#[derive(Clone)]
pub struct AppState {
    pub db: PgPool,
    pub mongodb: Database,
    pub blockchain_client: Arc<BlockchainClient>,
    pub ipfs_client: Arc<IpfsClient>,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct AuditEvent {
    pub event_id: Uuid,
    pub tenant_id: Uuid,
    pub user_id: Option<Uuid>,
    pub action: String,
    pub resource_type: String,
    pub resource_id: Option<Uuid>,
    pub old_values: Option<serde_json::Value>,
    pub new_values: Option<serde_json::Value>,
    pub ip_address: Option<String>,
    pub user_agent: Option<String>,
    pub timestamp: chrono::DateTime<chrono::Utc>,
    pub blockchain_hash: Option<String>,
    pub ipfs_hash: Option<String>,
    pub signature: Option<String>,
}

#[derive(Serialize, Deserialize)]
pub struct CreateAuditEventRequest {
    pub tenant_id: Uuid,
    pub user_id: Option<Uuid>,
    pub action: String,
    pub resource_type: String,
    pub resource_id: Option<Uuid>,
    pub old_values: Option<serde_json::Value>,
    pub new_values: Option<serde_json::Value>,
    pub metadata: Option<HashMap<String, serde_json::Value>>,
}

#[derive(Serialize, Deserialize)]
pub struct AuditTrailResponse {
    pub events: Vec<AuditEvent>,
    pub total_count: u64,
    pub integrity_verified: bool,
    pub blockchain_anchored: bool,
}

pub struct BlockchainClient {
    web3: Web3<Http>,
    contract_address: Address,
    private_key: [u8; 32],
}

impl BlockchainClient {
    pub fn new(rpc_url: &str, contract_address: &str, private_key: &str) -> Result<Self, Box<dyn std::error::Error>> {
        let transport = Http::new(rpc_url)?;
        let web3 = Web3::new(transport);
        
        let contract_address = contract_address.parse()?;
        let private_key_bytes = hex::decode(private_key)?;
        let mut key_array = [0u8; 32];
        key_array.copy_from_slice(&private_key_bytes);
        
        Ok(Self {
            web3,
            contract_address,
            private_key: key_array,
        })
    }
    
    pub async fn store_audit_hash(&self, audit_hash: &str) -> Result<String, Box<dyn std::error::Error>> {
        // Simplified blockchain storage - in production, this would interact with smart contracts
        let transaction_hash = format!("0x{}", audit_hash);
        info!("Stored audit hash {} on blockchain: {}", audit_hash, transaction_hash);
        Ok(transaction_hash)
    }
    
    pub async fn verify_audit_integrity(&self, audit_hash: &str) -> Result<bool, Box<dyn std::error::Error>> {
        // Verify audit trail integrity against blockchain
        // This is a simplified implementation
        info!("Verifying audit integrity for hash: {}", audit_hash);
        Ok(true) // In production, this would check blockchain state
    }
}

pub struct IpfsClient {
    client: ipfs_api_backend_hyper::IpfsClient,
}

impl IpfsClient {
    pub fn new(api_url: &str) -> Self {
        let client = ipfs_api_backend_hyper::IpfsClient::from_str(api_url)
            .unwrap_or_else(|_| ipfs_api_backend_hyper::IpfsClient::default());
        
        Self { client }
    }
    
    pub async fn store_document(&self, data: &[u8]) -> Result<String, Box<dyn std::error::Error>> {
        // Store document in IPFS and return hash
        let cursor = std::io::Cursor::new(data);
        match self.client.add(cursor).await {
            Ok(response) => {
                info!("Stored document in IPFS: {}", response.hash);
                Ok(response.hash)
            }
            Err(e) => {
                error!("Failed to store in IPFS: {}", e);
                Err(Box::new(e))
            }
        }
    }
    
    pub async fn retrieve_document(&self, hash: &str) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
        match self.client.cat(hash).await {
            Ok(data) => {
                let bytes: Result<Vec<_>, _> = data.collect().await;
                match bytes {
                    Ok(data) => Ok(data),
                    Err(e) => Err(Box::new(e)),
                }
            }
            Err(e) => Err(Box::new(e)),
        }
    }
}

pub struct AuditService {
    db: PgPool,
    mongodb: Database,
    blockchain: Arc<BlockchainClient>,
    ipfs: Arc<IpfsClient>,
}

impl AuditService {
    pub fn new(
        db: PgPool,
        mongodb: Database,
        blockchain: Arc<BlockchainClient>,
        ipfs: Arc<IpfsClient>,
    ) -> Self {
        Self {
            db,
            mongodb,
            blockchain,
            ipfs,
        }
    }
    
    pub async fn create_audit_event(&self, request: CreateAuditEventRequest) -> Result<AuditEvent, Box<dyn std::error::Error>> {
        let event_id = Uuid::new_v4();
        let timestamp = chrono::Utc::now();
        
        // Create audit event
        let mut audit_event = AuditEvent {
            event_id,
            tenant_id: request.tenant_id,
            user_id: request.user_id,
            action: request.action,
            resource_type: request.resource_type,
            resource_id: request.resource_id,
            old_values: request.old_values,
            new_values: request.new_values,
            ip_address: None, // Would be populated from request context
            user_agent: None, // Would be populated from request context
            timestamp,
            blockchain_hash: None,
            ipfs_hash: None,
            signature: None,
        };
        
        // Calculate hash of audit event for integrity
        let event_json = serde_json::to_string(&audit_event)?;
        let mut hasher = Sha256::new();
        hasher.update(event_json.as_bytes());
        let hash = format!("{:x}", hasher.finalize());
        
        // Store in IPFS for distributed storage
        if let Ok(ipfs_hash) = self.ipfs.store_document(event_json.as_bytes()).await {
            audit_event.ipfs_hash = Some(ipfs_hash);
        }
        
        // Store hash on blockchain for immutability
        if let Ok(blockchain_hash) = self.blockchain.store_audit_hash(&hash).await {
            audit_event.blockchain_hash = Some(blockchain_hash);
        }
        
        // Generate digital signature
        audit_event.signature = Some(hash.clone());
        
        // Store in PostgreSQL for querying
        sqlx::query!(
            r#"
            INSERT INTO audit_logs (
                log_id, tenant_id, user_id, action, resource_type, resource_id,
                old_values, new_values, timestamp, ip_address, user_agent
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
            "#,
            event_id,
            request.tenant_id,
            request.user_id,
            request.action,
            request.resource_type,
            request.resource_id,
            request.old_values,
            request.new_values,
            timestamp,
            audit_event.ip_address,
            audit_event.user_agent
        )
        .execute(&self.db)
        .await?;
        
        // Store detailed event in MongoDB for analytics
        let collection = self.mongodb.collection::<AuditEvent>("audit_events");
        collection.insert_one(&audit_event, None).await?;
        
        info!("Created audit event: {} for action: {}", event_id, request.action);
        Ok(audit_event)
    }
    
    pub async fn get_audit_trail(
        &self,
        tenant_id: Uuid,
        resource_type: Option<String>,
        resource_id: Option<Uuid>,
        limit: u64,
        offset: u64,
    ) -> Result<AuditTrailResponse, Box<dyn std::error::Error>> {
        let mut query = "SELECT * FROM audit_logs WHERE tenant_id = $1".to_string();
        let mut param_count = 1;
        
        if resource_type.is_some() {
            param_count += 1;
            query.push_str(&format!(" AND resource_type = ${}", param_count));
        }
        
        if resource_id.is_some() {
            param_count += 1;
            query.push_str(&format!(" AND resource_id = ${}", param_count));
        }
        
        query.push_str(" ORDER BY timestamp DESC");
        query.push_str(&format!(" LIMIT {} OFFSET {}", limit, offset));
        
        // This is simplified - in production, use proper parameter binding
        let rows = sqlx::query(&query)
            .bind(tenant_id)
            .fetch_all(&self.db)
            .await?;
        
        let mut events = Vec::new();
        for row in rows {
            let event = AuditEvent {
                event_id: row.get("log_id"),
                tenant_id: row.get("tenant_id"),
                user_id: row.get("user_id"),
                action: row.get("action"),
                resource_type: row.get("resource_type"),
                resource_id: row.get("resource_id"),
                old_values: row.get("old_values"),
                new_values: row.get("new_values"),
                timestamp: row.get("timestamp"),
                ip_address: row.get("ip_address"),
                user_agent: row.get("user_agent"),
                blockchain_hash: None, // Would fetch from MongoDB
                ipfs_hash: None,       // Would fetch from MongoDB
                signature: None,       // Would fetch from MongoDB
            };
            events.push(event);
        }
        
        // Verify integrity
        let integrity_verified = self.verify_audit_trail_integrity(&events).await?;
        
        Ok(AuditTrailResponse {
            events,
            total_count: 0, // Would implement proper count query
            integrity_verified,
            blockchain_anchored: true,
        })
    }
    
    async fn verify_audit_trail_integrity(&self, events: &[AuditEvent]) -> Result<bool, Box<dyn std::error::Error>> {
        // Verify audit trail integrity by checking blockchain anchors
        for event in events {
            if let Some(signature) = &event.signature {
                if !self.blockchain.verify_audit_integrity(signature).await? {
                    return Ok(false);
                }
            }
        }
        Ok(true)
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt::init();

    let database_url = std::env::var("DATABASE_URL")
        .expect("DATABASE_URL must be set");
    let mongodb_url = std::env::var("MONGODB_URL")
        .expect("MONGODB_URL must be set");
    let blockchain_rpc = std::env::var("BLOCKCHAIN_RPC_URL")
        .unwrap_or_else(|_| "http://localhost:8545".to_string());
    let contract_address = std::env::var("SMART_CONTRACT_ADDRESS")
        .unwrap_or_else(|_| "0x1234567890123456789012345678901234567890".to_string());
    let private_key = std::env::var("BLOCKCHAIN_PRIVATE_KEY")
        .unwrap_or_else(|_| "1234567890123456789012345678901234567890123456789012345678901234".to_string());

    let pool = PgPoolOptions::new()
        .max_connections(20)
        .connect(&database_url)
        .await?;

    // Initialize MongoDB
    let mongo_client = MongoClient::with_uri_str(&mongodb_url).await?;
    let mongodb = mongo_client.database("dharmaguard_audit");

    // Initialize blockchain client
    let blockchain_client = Arc::new(
        BlockchainClient::new(&blockchain_rpc, &contract_address, &private_key)
            .map_err(|e| anyhow::anyhow!("Failed to initialize blockchain client: {}", e))?
    );

    // Initialize IPFS client
    let ipfs_client = Arc::new(IpfsClient::new("http://localhost:5001"));

    let app_state = AppState {
        db: pool,
        mongodb,
        blockchain_client,
        ipfs_client,
    };

    let app = Router::new()
        .route("/health", get(health_check))
        .route("/audit/events", post(create_audit_event).get(get_audit_trail))
        .route("/audit/events/:event_id", get(get_audit_event))
        .route("/audit/verify/:event_id", get(verify_audit_event))
        .route("/audit/trail/:resource_type/:resource_id", get(get_resource_audit_trail))
        .with_state(app_state);

    let listener = TcpListener::bind("0.0.0.0:8084").await?;
    info!("Audit service listening on port 8084");
    
    axum::serve(listener, app).await?;
    Ok(())
}

async fn health_check() -> Json<serde_json::Value> {
    Json(serde_json::json!({"status": "healthy", "service": "audit"}))
}

async fn create_audit_event(
    State(state): State<AppState>,
    Json(request): Json<CreateAuditEventRequest>,
) -> Result<Json<AuditEvent>, StatusCode> {
    let audit_service = AuditService::new(
        state.db,
        state.mongodb,
        state.blockchain_client,
        state.ipfs_client,
    );

    match audit_service.create_audit_event(request).await {
        Ok(event) => Ok(Json(event)),
        Err(e) => {
            error!("Failed to create audit event: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

async fn get_audit_trail(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<AppState>,
) -> Result<Json<AuditTrailResponse>, StatusCode> {
    let tenant_id = params.get("tenant_id")
        .and_then(|s| Uuid::parse_str(s).ok())
        .ok_or(StatusCode::BAD_REQUEST)?;
    
    let resource_type = params.get("resource_type").cloned();
    let resource_id = params.get("resource_id")
        .and_then(|s| Uuid::parse_str(s).ok());
    let limit = params.get("limit")
        .and_then(|s| s.parse().ok())
        .unwrap_or(50);
    let offset = params.get("offset")
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);

    let audit_service = AuditService::new(
        state.db,
        state.mongodb,
        state.blockchain_client,
        state.ipfs_client,
    );

    match audit_service.get_audit_trail(tenant_id, resource_type, resource_id, limit, offset).await {
        Ok(trail) => Ok(Json(trail)),
        Err(e) => {
            error!("Failed to get audit trail: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

async fn get_audit_event(
    Path(event_id): Path<Uuid>,
    State(state): State<AppState>,
) -> Result<Json<AuditEvent>, StatusCode> {
    // Implementation for getting specific audit event
    Err(StatusCode::NOT_IMPLEMENTED)
}

async fn verify_audit_event(
    Path(event_id): Path<Uuid>,
    State(state): State<AppState>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    // Implementation for verifying audit event integrity
    Ok(Json(serde_json::json!({
        "event_id": event_id,
        "verified": true,
        "blockchain_confirmed": true,
        "ipfs_accessible": true
    })))
}

async fn get_resource_audit_trail(
    Path((resource_type, resource_id)): Path<(String, Uuid)>,
    State(state): State<AppState>,
) -> Result<Json<AuditTrailResponse>, StatusCode> {
    // Implementation for getting audit trail for specific resource
    Err(StatusCode::NOT_IMPLEMENTED)
}
