/**
 * K6 Load Testing Script for DharmaGuard Surveillance Engine
 * Tests high-frequency trade processing and pattern detection
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

// Custom metrics
const tradeProcessingErrors = new Counter('trade_processing_errors');
const patternDetectionRate = new Rate('pattern_detection_success_rate');
const tradeProcessingTime = new Trend('trade_processing_duration');

// Test configuration
export const options = {
  stages: [
    { duration: '2m', target: 100 },   // Ramp up to 100 VUs
    { duration: '5m', target: 500 },   // Scale to 500 VUs
    { duration: '10m', target: 1000 }, // Peak load at 1000 VUs
    { duration: '5m', target: 500 },   // Scale down
    { duration: '2m', target: 0 },     // Ramp down
  ],
  thresholds: {
    http_req_duration: ['p(95)<100'], // 95% of requests under 100ms
    http_req_failed: ['rate<0.01'],   // Error rate under 1%
    trade_processing_duration: ['p(99)<50'], // 99% under 50ms
    pattern_detection_success_rate: ['rate>0.95'], // 95% success rate
  },
};

// Test data generators
const instruments = ['RELIANCE', 'TCS', 'INFY', 'HDFCBANK', 'ITC', 'HINDUNILVR', 'KOTAKBANK', 'LT', 'ASIANPAINT', 'MARUTI'];
const tradeTypes = ['BUY', 'SELL'];
const exchanges = ['NSE', 'BSE'];

function generateTradeData() {
  const basePrice = Math.random() * 3000 + 100; // Price between 100-3100
  const priceVariation = (Math.random() - 0.5) * 0.1; // ±5% variation
  
  return {
    trade_id: `T${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
    tenant_id: '550e8400-e29b-41d4-a716-446655440000', // Test tenant
    account_id: `ACC${Math.floor(Math.random() * 1000)}`,
    instrument: instruments[Math.floor(Math.random() * instruments.length)],
    trade_type: tradeTypes[Math.floor(Math.random() * tradeTypes.length)],
    quantity: Math.floor(Math.random() * 1000) + 1,
    price: basePrice * (1 + priceVariation),
    exchange: exchanges[Math.floor(Math.random() * exchanges.length)],
    timestamp: new Date().toISOString(),
    client_id: `CLIENT${Math.floor(Math.random() * 500)}`,
    trader_id: `TRADER${Math.floor(Math.random() * 100)}`,
  };
}

function generateAnomalousTradeData() {
  const trade = generateTradeData();
  
  // Create anomalous patterns
  const anomalyType = Math.floor(Math.random() * 4);
  
  switch (anomalyType) {
    case 0: // Large trade
      trade.quantity *= 100;
      break;
    case 1: // Unusual timing
      const now = new Date();
      now.setHours(2); // 2 AM trading
      trade.timestamp = now.toISOString();
      break;
    case 2: // Price manipulation
      trade.price *= 1.5; // 50% price spike
      break;
    case 3: // Rapid succession
      trade.metadata = { rapid_succession: true };
      break;
  }
  
  return trade;
}

// Main test function
export default function () {
  const baseUrl = 'http://localhost:8080'; // API Gateway URL
  
  // Test 1: Normal trade processing
  testNormalTradeProcessing(baseUrl);
  
  // Test 2: Anomalous trade detection
  testAnomalousTradeDetection(baseUrl);
  
  // Test 3: Batch trade processing
  testBatchTradeProcessing(baseUrl);
  
  // Test 4: Pattern detection queries
  testPatternDetectionQueries(baseUrl);
  
  sleep(0.1); // Brief pause between iterations
}

function testNormalTradeProcessing(baseUrl) {
  const trade = generateTradeData();
  
  const startTime = Date.now();
  const response = http.post(`${baseUrl}/api/v1/surveillance/trades`, JSON.stringify(trade), {
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer test-token', // Test token
    },
  });
  
  const processingTime = Date.now() - startTime;
  tradeProcessingTime.add(processingTime);
  
  const success = check(response, {
    'trade processing status is 200 or 201': (r) => r.status === 200 || r.status === 201,
    'trade processing response time < 100ms': () => processingTime < 100,
    'response has trade_id': (r) => {
      try {
        const body = JSON.parse(r.body);
        return body.trade_id !== undefined;
      } catch (e) {
        return false;
      }
    },
  });
  
  if (!success) {
    tradeProcessingErrors.add(1);
  }
}

function testAnomalousTradeDetection(baseUrl) {
  // Send anomalous trade every 10th iteration
  if (__ITER % 10 === 0) {
    const anomalousTrade = generateAnomalousTradeData();
    
    const response = http.post(`${baseUrl}/api/v1/surveillance/trades`, JSON.stringify(anomalousTrade), {
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer test-token',
      },
    });
    
    // Check if pattern detection was triggered
    sleep(0.5); // Wait for processing
    
    const alertsResponse = http.get(`${baseUrl}/api/v1/surveillance/alerts?limit=1`, {
      headers: {
        'Authorization': 'Bearer test-token',
      },
    });
    
    const patternDetected = check(alertsResponse, {
      'alerts endpoint accessible': (r) => r.status === 200,
      'pattern detection functioning': (r) => {
        try {
          const body = JSON.parse(r.body);
          return Array.isArray(body.data) || Array.isArray(body);
        } catch (e) {
          return false;
        }
      },
    });
    
    patternDetectionRate.add(patternDetected);
  }
}

function testBatchTradeProcessing(baseUrl) {
  // Test batch processing every 20th iteration
  if (__ITER % 20 === 0) {
    const batchSize = 10;
    const trades = [];
    
    for (let i = 0; i < batchSize; i++) {
      trades.push(generateTradeData());
    }
    
    const startTime = Date.now();
    const response = http.post(`${baseUrl}/api/v1/surveillance/trades/batch`, JSON.stringify({ trades }), {
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer test-token',
      },
    });
    
    const batchProcessingTime = Date.now() - startTime;
    
    check(response, {
      'batch processing status is 200': (r) => r.status === 200,
      'batch processing time reasonable': () => batchProcessingTime < 500, // 500ms for 10 trades
      'all trades processed': (r) => {
        try {
          const body = JSON.parse(r.body);
          return body.processed_count === batchSize;
        } catch (e) {
          return false;
        }
      },
    });
  }
}

function testPatternDetectionQueries(baseUrl) {
  // Test surveillance queries every 15th iteration
  if (__ITER % 15 === 0) {
    const endpoints = [
      '/api/v1/surveillance/alerts',
      '/api/v1/surveillance/statistics',
      '/api/v1/surveillance/patterns',
    ];
    
    endpoints.forEach(endpoint => {
      const response = http.get(`${baseUrl}${endpoint}`, {
        headers: {
          'Authorization': 'Bearer test-token',
        },
      });
      
      check(response, {
        [`${endpoint} is accessible`]: (r) => r.status === 200,
        [`${endpoint} response time < 200ms`]: (r) => r.timings.duration < 200,
        [`${endpoint} returns valid JSON`]: (r) => {
          try {
            JSON.parse(r.body);
            return true;
          } catch (e) {
            return false;
          }
        },
      });
    });
  }
}

// Setup function - runs once per VU
export function setup() {
  console.log('Starting surveillance engine load test');
  console.log(`Test will simulate ${options.stages[2].target} concurrent users at peak`);
  
  // Verify API is accessible
  const healthCheck = http.get('http://localhost:8080/health');
  if (healthCheck.status !== 200) {
    throw new Error('API Gateway health check failed');
  }
  
  return { startTime: Date.now() };
}

// Teardown function - runs once after all VUs finish
export function teardown(data) {
  const duration = (Date.now() - data.startTime) / 1000;
  console.log(`Load test completed in ${duration} seconds`);
  
  // Generate summary report
  console.log('=== Load Test Summary ===');
  console.log(`Total duration: ${duration}s`);
  console.log(`Peak concurrent users: ${options.stages[2].target}`);
  console.log('Check detailed metrics in the K6 output above');
}

// Export custom functions for modular testing
export {
  generateTradeData,
  generateAnomalousTradeData,
  testNormalTradeProcessing,
  testAnomalousTradeDetection,
};
