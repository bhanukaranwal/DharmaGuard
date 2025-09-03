"""
DharmaGuard ML Platform - Anomaly Detection Model
Advanced anomaly detection for financial trading patterns
"""

import numpy as np
import pandas as pd
from typing import Dict, List, Optional, Tuple, Any
from sklearn.ensemble import IsolationForest
from sklearn.preprocessing import StandardScaler
from sklearn.metrics import classification_report, roc_auc_score
import joblib
import logging
from datetime import datetime, timedelta
import redis
import psycopg2
from psycopg2.extras import RealDictCursor
import json

logger = logging.getLogger(__name__)

class AnomalyDetector:
    """
    Advanced anomaly detection for trading surveillance
    Uses ensemble methods for robust detection
    """
    
    def __init__(self, 
                 contamination: float = 0.1,
                 random_state: int = 42,
                 model_type: str = "isolation_forest"):
        """
        Initialize anomaly detector
        
        Args:
            contamination: Expected proportion of outliers
            random_state: Random state for reproducibility
            model_type: Type of model to use
        """
        self.contamination = contamination
        self.random_state = random_state
        self.model_type = model_type
        self.model = None
        self.scaler = StandardScaler()
        self.feature_columns = []
        self.is_trained = False
        
        # Initialize model based on type
        if model_type == "isolation_forest":
            self.model = IsolationForest(
                contamination=contamination,
                random_state=random_state,
                n_estimators=200,
                max_samples='auto',
                max_features=1.0,
                bootstrap=False,
                n_jobs=-1,
                warm_start=False
            )
    
    def extract_features(self, trade_data: pd.DataFrame) -> pd.DataFrame:
        """
        Extract features for anomaly detection
        
        Args:
            trade_data: Raw trade data
            
        Returns:
            Feature matrix
        """
        features = pd.DataFrame()
        
        # Basic trade features
        features['trade_size'] = trade_data['quantity'] * trade_data['price']
        features['price_change'] = trade_data.groupby('instrument')['price'].pct_change().fillna(0)
        features['volume_ratio'] = (trade_data['quantity'] / 
                                  trade_data.groupby('instrument')['quantity'].transform('mean'))
        
        # Time-based features
        trade_data['hour'] = pd.to_datetime(trade_data['timestamp']).dt.hour
        trade_data['minute'] = pd.to_datetime(trade_data['timestamp']).dt.minute
        features['trading_hour'] = trade_data['hour']
        features['trading_minute'] = trade_data['minute']
        
        # Account-based features
        features['account_trade_frequency'] = (trade_data.groupby('account_id')
                                             .cumcount() + 1)
        
        # Instrument-based features
        features['instrument_volatility'] = (trade_data.groupby('instrument')['price']
                                           .rolling(window=10, min_periods=1)
                                           .std().fillna(0))
        
        # Statistical features
        features['price_zscore'] = ((trade_data['price'] - 
                                   trade_data.groupby('instrument')['price'].transform('mean')) /
                                  trade_data.groupby('instrument')['price'].transform('std').fillna(1))
        
        features['volume_zscore'] = ((trade_data['quantity'] - 
                                    trade_data.groupby('instrument')['quantity'].transform('mean')) /
                                   trade_data.groupby('instrument')['quantity'].transform('std').fillna(1))
        
        # Sequential features
        features['rapid_succession'] = (trade_data.groupby(['account_id', 'instrument'])['timestamp']
                                      .diff().dt.total_seconds().fillna(0) < 10).astype(int)
        
        # Market timing features
        features['market_open_proximity'] = np.abs(trade_data['hour'] - 9)  # NSE opens at 9:15
        features['market_close_proximity'] = np.abs(trade_data['hour'] - 15)  # NSE closes at 3:30
        
        # Fill NaN values
        features = features.fillna(0)
        
        self.feature_columns = features.columns.tolist()
        return features
    
    def train(self, trade_data: pd.DataFrame, 
              labeled_anomalies: Optional[pd.Series] = None) -> Dict[str, float]:
        """
        Train the anomaly detection model
        
        Args:
            trade_data: Training data
            labeled_anomalies: Optional labeled anomalies for evaluation
            
        Returns:
            Training metrics
        """
        logger.info(f"Training anomaly detector with {len(trade_data)} samples")
        
        # Extract features
        features = self.extract_features(trade_data)
        
        # Scale features
        features_scaled = self.scaler.fit_transform(features)
        
        # Train model
        self.model.fit(features_scaled)
        self.is_trained = True
        
        # Evaluate if labeled data is available
        metrics = {}
        if labeled_anomalies is not None:
            predictions = self.model.predict(features_scaled)
            # Convert to binary (1 for normal, -1 for anomaly -> 0 for normal, 1 for anomaly)
            predictions_binary = (predictions == -1).astype(int)
            
            if len(np.unique(labeled_anomalies)) > 1:
                metrics['auc'] = roc_auc_score(labeled_anomalies, predictions_binary)
                logger.info(f"Training AUC: {metrics['auc']:.3f}")
        
        logger.info("Anomaly detector training completed")
        return metrics
    
    def predict(self, trade_data: pd.DataFrame) -> Tuple[np.ndarray, np.ndarray]:
        """
        Predict anomalies in trade data
        
        Args:
            trade_data: Trade data to analyze
            
        Returns:
            Tuple of (predictions, anomaly_scores)
        """
        if not self.is_trained:
            raise ValueError("Model must be trained before making predictions")
        
        # Extract features
        features = self.extract_features(trade_data)
        
        # Scale features
        features_scaled = self.scaler.transform(features)
        
        # Make predictions
        predictions = self.model.predict(features_scaled)
        anomaly_scores = self.model.decision_function(features_scaled)
        
        # Convert predictions to binary (0 = normal, 1 = anomaly)
        predictions_binary = (predictions == -1).astype(int)
        
        return predictions_binary, anomaly_scores
    
    def detect_patterns(self, trade_data: pd.DataFrame) -> List[Dict[str, Any]]:
        """
        Detect specific anomaly patterns
        
        Args:
            trade_data: Trade data to analyze
            
        Returns:
            List of detected patterns with details
        """
        if not self.is_trained:
            raise ValueError("Model must be trained before detecting patterns")
        
        predictions, scores = self.predict(trade_data)
        
        patterns = []
        anomaly_indices = np.where(predictions == 1)[0]
        
        for idx in anomaly_indices:
            trade = trade_data.iloc[idx]
            score = scores[idx]
            
            # Determine pattern type based on features
            pattern_type = self._classify_anomaly_type(trade, trade_data)
            
            pattern = {
                'trade_id': trade.get('trade_id', f'trade_{idx}'),
                'timestamp': trade['timestamp'],
                'account_id': trade['account_id'],
                'instrument': trade['instrument'],
                'pattern_type': pattern_type,
                'anomaly_score': float(score),
                'confidence': float(1 / (1 + np.exp(score))),  # Sigmoid transformation
                'details': self._get_pattern_details(trade, trade_data, pattern_type)
            }
            patterns.append(pattern)
        
        return patterns
    
    def _classify_anomaly_type(self, trade: pd.Series, all_trades: pd.DataFrame) -> str:
        """
        Classify the type of anomaly detected
        """
        # Simple pattern classification based on trade characteristics
        trade_size = trade['quantity'] * trade['price']
        
        # Check for large trade size
        if trade_size > all_trades['quantity'].mean() * all_trades['price'].mean() * 10:
            return "UNUSUALLY_LARGE_TRADE"
        
        # Check for rapid succession of trades
        same_account_trades = all_trades[all_trades['account_id'] == trade['account_id']]
        if len(same_account_trades) > 1:
            time_diffs = pd.to_datetime(same_account_trades['timestamp']).diff().dt.total_seconds()
            if (time_diffs < 10).any():
                return "RAPID_TRADING"
        
        # Check for off-hours trading
        trade_hour = pd.to_datetime(trade['timestamp']).hour
        if trade_hour < 9 or trade_hour > 15:
            return "OFF_HOURS_TRADING"
        
        # Check for unusual price movement
        same_instrument = all_trades[all_trades['instrument'] == trade['instrument']]
        if len(same_instrument) > 1:
            price_change = abs(trade['price'] - same_instrument['price'].median()) / same_instrument['price'].median()
            if price_change > 0.1:  # 10% price deviation
                return "UNUSUAL_PRICE_MOVEMENT"
        
        return "GENERAL_ANOMALY"
    
    def _get_pattern_details(self, trade: pd.Series, all_trades: pd.DataFrame, pattern_type: str) -> Dict[str, Any]:
        """
        Get detailed information about the detected pattern
        """
        details = {
            'trade_size': float(trade['quantity'] * trade['price']),
            'price': float(trade['price']),
            'quantity': int(trade['quantity'])
        }
        
        if pattern_type == "UNUSUALLY_LARGE_TRADE":
            avg_size = all_trades['quantity'].mean() * all_trades['price'].mean()
            details['size_multiple'] = float(details['trade_size'] / avg_size)
        
        elif pattern_type == "RAPID_TRADING":
            same_account_trades = all_trades[all_trades['account_id'] == trade['account_id']]
            details['trade_count'] = len(same_account_trades)
            if len(same_account_trades) > 1:
                time_diffs = pd.to_datetime(same_account_trades['timestamp']).diff().dt.total_seconds()
                details['min_time_gap'] = float(time_diffs.min())
        
        return details
    
    def save_model(self, filepath: str) -> None:
        """Save the trained model"""
        if not self.is_trained:
            raise ValueError("Cannot save untrained model")
        
        model_data = {
            'model': self.model,
            'scaler': self.scaler,
            'feature_columns': self.feature_columns,
            'contamination': self.contamination,
            'model_type': self.model_type
        }
        
        joblib.dump(model_data, filepath)
        logger.info(f"Model saved to {filepath}")
    
    def load_model(self, filepath: str) -> None:
        """Load a trained model"""
        model_data = joblib.load(filepath)
        
        self.model = model_data['model']
        self.scaler = model_data['scaler']
        self.feature_columns = model_data['feature_columns']
        self.contamination = model_data['contamination']
        self.model_type = model_data['model_type']
        self.is_trained = True
        
        logger.info(f"Model loaded from {filepath}")

class RealTimeAnomalyDetector:
    """
    Real-time anomaly detection with streaming capabilities
    """
    
    def __init__(self, model_path: str, redis_config: Dict, db_config: Dict):
        """
        Initialize real-time detector
        
        Args:
            model_path: Path to saved model
            redis_config: Redis configuration
            db_config: Database configuration
        """
        self.detector = AnomalyDetector()
        self.detector.load_model(model_path)
        
        # Initialize connections
        self.redis_client = redis.Redis(**redis_config)
        self.db_config = db_config
        
        # Buffer for batch processing
        self.trade_buffer = []
        self.buffer_size = 100
        
    def process_trade(self, trade_data: Dict) -> Optional[Dict]:
        """
        Process a single trade for anomaly detection
        
        Args:
            trade_data: Trade data dictionary
            
        Returns:
            Anomaly alert if detected, None otherwise
        """
        # Add to buffer
        self.trade_buffer.append(trade_data)
        
        # Process when buffer is full
        if len(self.trade_buffer) >= self.buffer_size:
            return self._process_buffer()
        
        # For critical trades, process immediately
        if self._is_critical_trade(trade_data):
            return self._process_single_trade(trade_data)
        
        return None
    
    def _is_critical_trade(self, trade_data: Dict) -> bool:
        """Check if trade requires immediate processing"""
        trade_value = trade_data.get('quantity', 0) * trade_data.get('price', 0)
        return trade_value > 10000000  # 1 Crore threshold
    
    def _process_single_trade(self, trade_data: Dict) -> Optional[Dict]:
        """Process a single trade immediately"""
        df = pd.DataFrame([trade_data])
        predictions, scores = self.detector.predict(df)
        
        if predictions[0] == 1:  # Anomaly detected
            return {
                'alert_type': 'REAL_TIME_ANOMALY',
                'trade_id': trade_data.get('trade_id'),
                'anomaly_score': float(scores[0]),
                'timestamp': datetime.utcnow().isoformat(),
                'details': trade_data
            }
        
        return None
    
    def _process_buffer(self) -> List[Dict]:
        """Process the entire buffer"""
        if not self.trade_buffer:
            return []
        
        df = pd.DataFrame(self.trade_buffer)
        patterns = self.detector.detect_patterns(df)
        
        # Clear buffer
        self.trade_buffer = []
        
        # Convert to alerts
        alerts = []
        for pattern in patterns:
            alert = {
                'alert_type': 'BATCH_ANOMALY',
                'pattern_type': pattern['pattern_type'],
                'anomaly_score': pattern['anomaly_score'],
                'confidence': pattern['confidence'],
                'timestamp': datetime.utcnow().isoformat(),
                'details': pattern
            }
            alerts.append(alert)
            
            # Store in Redis for real-time access
            self.redis_client.setex(
                f"anomaly_alert:{pattern['trade_id']}", 
                3600,  # 1 hour expiry
                json.dumps(alert)
            )
        
        return alerts

# Example usage and testing
if __name__ == "__main__":
    # Sample trade data for testing
    sample_data = pd.DataFrame({
        'trade_id': [f'T{i}' for i in range(1000)],
        'timestamp': pd.date_range('2023-01-01 09:15:00', periods=1000, freq='1min'),
        'account_id': np.random.choice(['A1', 'A2', 'A3', 'A4', 'A5'], 1000),
        'instrument': np.random.choice(['RELIANCE', 'TCS', 'INFY', 'HDFCBANK'], 1000),
        'quantity': np.random.randint(1, 1000, 1000),
        'price': np.random.uniform(100, 3000, 1000),
        'trade_type': np.random.choice(['BUY', 'SELL'], 1000)
    })
    
    # Add some anomalies
    anomaly_indices = np.random.choice(1000, 50, replace=False)
    sample_data.loc[anomaly_indices, 'quantity'] *= 10  # Large trades
    sample_data.loc[anomaly_indices[:25], 'price'] *= 1.5  # Price spikes
    
    # Train detector
    detector = AnomalyDetector(contamination=0.05)
    metrics = detector.train(sample_data)
    
    # Detect patterns
    patterns = detector.detect_patterns(sample_data)
    print(f"Detected {len(patterns)} anomalous patterns")
    
    for pattern in patterns[:5]:  # Show first 5
        print(f"Pattern: {pattern['pattern_type']}, Score: {pattern['anomaly_score']:.3f}")
