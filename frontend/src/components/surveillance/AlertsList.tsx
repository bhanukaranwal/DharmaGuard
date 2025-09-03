'use client';

import React, { useState, useEffect } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { 
  ExclamationTriangleIcon,
  ShieldExclamationIcon,
  InformationCircleIcon,
  CheckCircleIcon,
  EyeIcon,
  ClockIcon,
  UserIcon
} from '@heroicons/react/24/outline';
import { format, formatDistanceToNow } from 'date-fns';

interface Alert {
  alert_id: string;
  pattern_type: string;
  severity: 'LOW' | 'MEDIUM' | 'HIGH' | 'CRITICAL';
  status: 'OPEN' | 'INVESTIGATING' | 'RESOLVED' | 'FALSE_POSITIVE';
  title: string;
  description: string;
  risk_score: number;
  confidence_level: number;
  detection_timestamp: string;
  assigned_to?: string;
  created_at: string;
}

interface AlertsListProps {
  alerts: Alert[];
  compact?: boolean;
  onAlertClick?: (alert: Alert) => void;
  onStatusChange?: (alertId: string, status: string) => void;
}

const severityConfig = {
  LOW: {
    icon: InformationCircleIcon,
    color: 'text-blue-600',
    bgColor: 'bg-blue-50',
    borderColor: 'border-blue-200',
  },
  MEDIUM: {
    icon: ExclamationTriangleIcon,
    color: 'text-yellow-600',
    bgColor: 'bg-yellow-50',
    borderColor: 'border-yellow-200',
  },
  HIGH: {
    icon: ExclamationTriangleIcon,
    color: 'text-orange-600',
    bgColor: 'bg-orange-50',
    borderColor: 'border-orange-200',
  },
  CRITICAL: {
    icon: ShieldExclamationIcon,
    color: 'text-red-600',
    bgColor: 'bg-red-50',
    borderColor: 'border-red-200',
  },
};

const statusConfig = {
  OPEN: {
    label: 'Open',
    color: 'text-red-700',
    bgColor: 'bg-red-100',
  },
  INVESTIGATING: {
    label: 'Investigating',
    color: 'text-yellow-700',
    bgColor: 'bg-yellow-100',
  },
  RESOLVED: {
    label: 'Resolved',
    color: 'text-green-700',
    bgColor: 'bg-green-100',
  },
  FALSE_POSITIVE: {
    label: 'False Positive',
    color: 'text-gray-700',
    bgColor: 'bg-gray-100',
  },
};

export const AlertsList: React.FC<AlertsListProps> = ({
  alerts,
  compact = false,
  onAlertClick,
  onStatusChange,
}) => {
  const [sortBy, setSortBy] = useState<'timestamp' | 'severity' | 'risk_score'>('timestamp');
  const [sortOrder, setSortOrder] = useState<'asc' | 'desc'>('desc');
  const [filterSeverity, setFilterSeverity] = useState<string>('all');
  const [filterStatus, setFilterStatus] = useState<string>('all');

  const sortedAndFilteredAlerts = React.useMemo(() => {
    let filtered = alerts;

    // Apply filters
    if (filterSeverity !== 'all') {
      filtered = filtered.filter(alert => alert.severity === filterSeverity);
    }
    if (filterStatus !== 'all') {
      filtered = filtered.filter(alert => alert.status === filterStatus);
    }

    // Apply sorting
    return filtered.sort((a, b) => {
      let aValue: any, bValue: any;

      switch (sortBy) {
        case 'timestamp':
          aValue = new Date(a.detection_timestamp).getTime();
          bValue = new Date(b.detection_timestamp).getTime();
          break;
        case 'severity':
          const severityOrder = { 'LOW': 1, 'MEDIUM': 2, 'HIGH': 3, 'CRITICAL': 4 };
          aValue = severityOrder[a.severity];
          bValue = severityOrder[b.severity];
          break;
        case 'risk_score':
          aValue = a.risk_score;
          bValue = b.risk_score;
          break;
        default:
          aValue = a.detection_timestamp;
          bValue = b.detection_timestamp;
      }

      if (sortOrder === 'asc') {
        return aValue > bValue ? 1 : -1;
      } else {
        return aValue < bValue ? 1 : -1;
      }
    });
  }, [alerts, sortBy, sortOrder, filterSeverity, filterStatus]);

  const handleStatusChange = (alertId: string, newStatus: string) => {
    if (onStatusChange) {
      onStatusChange(alertId, newStatus);
    }
  };

  if (alerts.length === 0) {
    return (
      <div className="text-center py-8">
        <CheckCircleIcon className="mx-auto h-12 w-12 text-green-400" />
        <h3 className="mt-2 text-sm font-medium text-gray-900">No alerts</h3>
        <p className="mt-1 text-sm text-gray-500">
          All surveillance patterns are running normally.
        </p>
      </div>
    );
  }

  return (
    <div className="space-y-4">
      {/* Filters and Sorting - Only show if not compact */}
      {!compact && (
        <div className="flex flex-col sm:flex-row gap-4 p-4 bg-gray-50 rounded-lg">
          <div className="flex-1">
            <label htmlFor="sort-by" className="block text-sm font-medium text-gray-700">
              Sort by
            </label>
            <select
              id="sort-by"
              value={sortBy}
              onChange={(e) => setSortBy(e.target.value as any)}
              className="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-primary-500 focus:ring-primary-500 sm:text-sm"
            >
              <option value="timestamp">Detection Time</option>
              <option value="severity">Severity</option>
              <option value="risk_score">Risk Score</option>
            </select>
          </div>
          
          <div className="flex-1">
            <label htmlFor="sort-order" className="block text-sm font-medium text-gray-700">
              Order
            </label>
            <select
              id="sort-order"
              value={sortOrder}
              onChange={(e) => setSortOrder(e.target.value as 'asc' | 'desc')}
              className="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-primary-500 focus:ring-primary-500 sm:text-sm"
            >
              <option value="desc">Descending</option>
              <option value="asc">Ascending</option>
            </select>
          </div>
          
          <div className="flex-1">
            <label htmlFor="filter-severity" className="block text-sm font-medium text-gray-700">
              Severity
            </label>
            <select
              id="filter-severity"
              value={filterSeverity}
              onChange={(e) => setFilterSeverity(e.target.value)}
              className="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-primary-500 focus:ring-primary-500 sm:text-sm"
            >
              <option value="all">All Severities</option>
              <option value="CRITICAL">Critical</option>
              <option value="HIGH">High</option>
              <option value="MEDIUM">Medium</option>
              <option value="LOW">Low</option>
            </select>
          </div>
          
          <div className="flex-1">
            <label htmlFor="filter-status" className="block text-sm font-medium text-gray-700">
              Status
            </label>
            <select
              id="filter-status"
              value={filterStatus}
              onChange={(e) => setFilterStatus(e.target.value)}
              className="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-primary-500 focus:ring-primary-500 sm:text-sm"
            >
              <option value="all">All Statuses</option>
              <option value="OPEN">Open</option>
              <option value="INVESTIGATING">Investigating</option>
              <option value="RESOLVED">Resolved</option>
              <option value="FALSE_POSITIVE">False Positive</option>
            </select>
          </div>
        </div>
      )}

      {/* Alerts List */}
      <div className="space-y-3">
        <AnimatePresence>
          {sortedAndFilteredAlerts.map((alert, index) => {
            const SeverityIcon = severityConfig[alert.severity].icon;
            const severityStyle = severityConfig[alert.severity];
            const statusStyle = statusConfig[alert.status];

            return (
              <motion.div
                key={alert.alert_id}
                initial={{ opacity: 0, y: 20 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, y: -20 }}
                transition={{ duration: 0.3, delay: index * 0.05 }}
                className={`
                  border rounded-lg p-4 hover:shadow-md transition-shadow cursor-pointer
                  ${severityStyle.bgColor} ${severityStyle.borderColor}
                  ${compact ? 'py-3' : ''}
                `}
                onClick={() => onAlertClick?.(alert)}
              >
                <div className="flex items-start space-x-3">
                  {/* Severity Icon */}
                  <div className={`flex-shrink-0 ${severityStyle.color}`}>
                    <SeverityIcon className={`${compact ? 'h-5 w-5' : 'h-6 w-6'}`} />
                  </div>

                  {/* Alert Content */}
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center justify-between">
                      <h4 className={`font-medium text-gray-900 ${compact ? 'text-sm' : 'text-base'}`}>
                        {alert.title}
                      </h4>
                      <div className="flex items-center space-x-2">
                        <span className={`
                          px-2 py-1 text-xs font-medium rounded-full
                          ${statusStyle.bgColor} ${statusStyle.color}
                        `}>
                          {statusStyle.label}
                        </span>
                        {!compact && (
                          <select
                            value={alert.status}
                            onChange={(e) => {
                              e.stopPropagation();
                              handleStatusChange(alert.alert_id, e.target.value);
                            }}
                            className="text-xs border-gray-300 rounded focus:ring-primary-500 focus:border-primary-500"
                            onClick={(e) => e.stopPropagation()}
                          >
                            <option value="OPEN">Open</option>
                            <option value="INVESTIGATING">Investigating</option>
                            <option value="RESOLVED">Resolved</option>
                            <option value="FALSE_POSITIVE">False Positive</option>
                          </select>
                        )}
                      </div>
                    </div>

                    <p className={`text-gray-600 mt-1 ${compact ? 'text-xs' : 'text-sm'}`}>
                      {alert.description}
                    </p>

                    {/* Alert Metadata */}
                    <div className={`mt-2 flex items-center space-x-4 text-gray-500 ${compact ? 'text-xs' : 'text-sm'}`}>
                      <div className="flex items-center space-x-1">
                        <ClockIcon className="h-4 w-4" />
                        <span>
                          {formatDistanceToNow(new Date(alert.detection_timestamp), { addSuffix: true })}
                        </span>
                      </div>
                      
                      <div className="flex items-center space-x-1">
                        <EyeIcon className="h-4 w-4" />
                        <span>Pattern: {alert.pattern_type}</span>
                      </div>
                      
                      {!compact && (
                        <>
                          <div className="flex items-center space-x-1">
                            <span>Risk: {alert.risk_score}%</span>
                          </div>
                          
                          <div className="flex items-center space-x-1">
                            <span>Confidence: {alert.confidence_level}%</span>
                          </div>
                          
                          {alert.assigned_to && (
                            <div className="flex items-center space-x-1">
                              <UserIcon className="h-4 w-4" />
                              <span>Assigned</span>
                            </div>
                          )}
                        </>
                      )}
                    </div>
                  </div>
                </div>
              </motion.div>
            );
          })}
        </AnimatePresence>
      </div>

      {/* Summary */}
      {!compact && sortedAndFilteredAlerts.length > 0 && (
        <div className="mt-4 p-3 bg-gray-50 rounded-lg">
          <div className="text-sm text-gray-600">
            Showing {sortedAndFilteredAlerts.length} of {alerts.length} alerts
            {filterSeverity !== 'all' && (
              <span className="ml-2">
                (filtered by {filterSeverity.toLowerCase()} severity)
              </span>
            )}
            {filterStatus !== 'all' && (
              <span className="ml-2">
                (filtered by {statusConfig[filterStatus as keyof typeof statusConfig]?.label.toLowerCase()} status)
              </span>
            )}
          </div>
        </div>
      )}
    </div>
  );
};

export default AlertsList;
