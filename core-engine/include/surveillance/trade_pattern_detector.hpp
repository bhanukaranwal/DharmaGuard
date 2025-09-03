#pragma once

#include <memory>
#include <vector>
#include <unordered_map>
#include <string>
#include <chrono>
#include <atomic>
#include <thread>
#include <queue>
#include <mutex>
#include <condition_variable>
#include <tbb/concurrent_queue.h>
#include <tbb/concurrent_unordered_map.h>
#include <boost/lockfree/queue.hpp>

#include "trade_data.hpp"
#include "pattern_config.hpp"
#include "surveillance_alert.hpp"

namespace dharmaguard {
namespace surveillance {

/**
 * @brief High-performance trade pattern detection engine
 * 
 * This class implements a multi-threaded, lock-free pattern detection system
 * capable of processing millions of trades per second with sub-microsecond
 * latency for individual pattern checks.
 */
class TradePatternDetector {
public:
    /**
     * @brief Constructor
     * @param num_threads Number of worker threads for parallel processing
     * @param queue_size Size of the lock-free processing queue
     */
    explicit TradePatternDetector(size_t num_threads = std::thread::hardware_concurrency(),
                                size_t queue_size = 1000000);
    
    /**
     * @brief Destructor - ensures clean shutdown
     */
    ~TradePatternDetector();

    /**
     * @brief Initialize the detector with configuration
     * @param config_path Path to pattern configuration file
     * @return true if initialization successful
     */
    bool initialize(const std::string& config_path);

    /**
     * @brief Start the detection engine
     * @return true if started successfully
     */
    bool start();

    /**
     * @brief Stop the detection engine gracefully
     */
    void stop();

    /**
     * @brief Process a single trade for pattern detection
     * @param trade Trade data to process
     * @return true if trade was queued successfully
     */
    bool process_trade(const TradeData& trade);

    /**
     * @brief Process multiple trades in batch for efficiency
     * @param trades Vector of trades to process
     * @return Number of trades successfully queued
     */
    size_t process_trades_batch(const std::vector<TradeData>& trades);

    /**
     * @brief Register a custom pattern detector
     * @param pattern_name Name of the pattern
     * @param detector Shared pointer to pattern detector implementation
     */
    void register_pattern_detector(const std::string& pattern_name,
                                 std::shared_ptr<IPatternDetector> detector);

    /**
     * @brief Get current processing statistics
     * @return ProcessingStats structure with performance metrics
     */
    ProcessingStats get_statistics() const;

    /**
     * @brief Set alert callback function
     * @param callback Function to call when alerts are generated
     */
    void set_alert_callback(std::function<void(const SurveillanceAlert&)> callback);

    /**
     * @brief Enable/disable specific pattern detection
     * @param pattern_name Name of the pattern to toggle
     * @param enabled Whether to enable or disable
     */
    void toggle_pattern(const std::string& pattern_name, bool enabled);

    /**
     * @brief Update pattern configuration at runtime
     * @param pattern_name Name of the pattern to update
     * @param config New configuration parameters
     */
    void update_pattern_config(const std::string& pattern_name, 
                             const PatternConfig& config);

private:
    // Core processing components
    std::unique_ptr<class TradeProcessorImpl> impl_;
    
    // Thread management
    std::vector<std::thread> worker_threads_;
    std::atomic<bool> running_;
    std::atomic<bool> shutdown_requested_;
    
    // Lock-free trade queue for high-throughput processing
    boost::lockfree::queue<TradeData*> trade_queue_;
    
    // Pattern detectors registry
    tbb::concurrent_unordered_map<std::string, std::shared_ptr<IPatternDetector>> detectors_;
    
    // Configuration and statistics
    std::unique_ptr<PatternConfigManager> config_manager_;
    mutable std::mutex stats_mutex_;
    ProcessingStats statistics_;
    
    // Alert handling
    std::function<void(const SurveillanceAlert&)> alert_callback_;
    tbb::concurrent_queue<SurveillanceAlert> alert_queue_;
    std::thread alert_dispatcher_thread_;
    
    // Performance monitoring
    std::chrono::high_resolution_clock::time_point last_stats_update_;
    std::atomic<uint64_t> trades_processed_;
    std::atomic<uint64_t> alerts_generated_;
    std::atomic<uint64_t> processing_time_ns_;
    
    // Memory management for zero-copy processing
    std::unique_ptr<class MemoryPool> memory_pool_;
    
    // Worker thread function
    void worker_thread_func();
    
    // Alert dispatcher thread function
    void alert_dispatcher_func();
    
    // Process single trade (internal)
    void process_trade_internal(const TradeData& trade);
    
    // Update processing statistics
    void update_statistics();
    
    // Initialize built-in pattern detectors
    void initialize_builtin_detectors();
    
    // Load configuration from file
    bool load_configuration(const std::string& config_path);
    
    // Validate trade data
    bool validate_trade_data(const TradeData& trade) const;
};

/**
 * @brief Interface for pattern detector implementations
 */
class IPatternDetector {
public:
    virtual ~IPatternDetector() = default;
    
    /**
     * @brief Detect pattern in trade data
     * @param trade Current trade to analyze
     * @param historical_context Historical data for context
     * @return Optional alert if pattern detected
     */
    virtual std::optional<SurveillanceAlert> detect_pattern(
        const TradeData& trade,
        const HistoricalContext& historical_context) = 0;
    
    /**
     * @brief Update detector configuration
     * @param config New configuration parameters
     */
    virtual void update_config(const PatternConfig& config) = 0;
    
    /**
     * @brief Get detector name
     * @return String identifier for the detector
     */
    virtual std::string get_name() const = 0;
    
    /**
     * @brief Check if detector is enabled
     * @return true if detector is active
     */
    virtual bool is_enabled() const = 0;
    
    /**
     * @brief Enable or disable the detector
     * @param enabled New enabled state
     */
    virtual void set_enabled(bool enabled) = 0;
};

/**
 * @brief Processing statistics structure
 */
struct ProcessingStats {
    uint64_t total_trades_processed = 0;
    uint64_t total_alerts_generated = 0;
    uint64_t queue_size = 0;
    uint64_t avg_processing_time_ns = 0;
    uint64_t peak_processing_time_ns = 0;
    double throughput_trades_per_second = 0.0;
    double cpu_utilization_percent = 0.0;
    uint64_t memory_usage_bytes = 0;
    std::chrono::system_clock::time_point last_updated;
    
    // Per-pattern statistics
    std::unordered_map<std::string, uint64_t> pattern_alerts_count;
    std::unordered_map<std::string, uint64_t> pattern_processing_time_ns;
};

/**
 * @brief Trade data structure optimized for high-frequency processing
 */
struct TradeData {
    // Core trade information
    std::string trade_id;
    std::string instrument_symbol;
    std::string account_id;
    std::string client_id;
    
    // Trade details
    enum class TradeType { BUY, SELL, SHORT_SELL, COVER } trade_type;
    enum class MarketSegment { EQUITY, FUTURES, OPTIONS, COMMODITY, CURRENCY } segment;
    
    uint64_t quantity;
    double price;
    double value;
    std::string exchange;
    std::chrono::system_clock::time_point timestamp;
    
    // Extended information for surveillance
    std::string order_id;
    std::string trader_id;
    bool is_own_account;
    double brokerage;
    double taxes;
    
    // Performance optimization: avoid string allocations
    uint32_t instrument_id_hash;
    uint32_t account_id_hash;
    uint32_t client_id_hash;
    
    // Validation
    bool is_valid() const {
        return !trade_id.empty() && 
               !instrument_symbol.empty() && 
               quantity > 0 && 
               price > 0.0 && 
               value > 0.0;
    }
};

/**
 * @brief Historical context for pattern detection
 */
struct HistoricalContext {
    // Time window configuration
    std::chrono::minutes lookback_window{5};
    
    // Recent trades for the same instrument
    std::vector<TradeData> recent_trades;
    
    // Volume and price statistics
    double avg_volume = 0.0;
    double avg_price = 0.0;
    double price_volatility = 0.0;
    
    // Market data
    double bid_price = 0.0;
    double ask_price = 0.0;
    uint64_t bid_quantity = 0;
    uint64_t ask_quantity = 0;
    
    // Account-specific history
    std::vector<TradeData> account_recent_trades;
    double account_total_volume = 0.0;
    
    // Cross-references
    std::vector<std::string> related_accounts;
    std::vector<std::string> related_instruments;
};

} // namespace surveillance
} // namespace dharmaguard
