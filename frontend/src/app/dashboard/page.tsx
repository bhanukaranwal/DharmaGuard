'use client';

import React, { useEffect, useState } from 'react';
import { motion } from 'framer-motion';
import { 
  ChartBarIcon, 
  ExclamationTriangleIcon, 
  CheckCircleIcon, 
  ClockIcon,
  TrendingUpIcon,
  UsersIcon,
  ShieldCheckIcon,
  CurrencyDollarIcon
} from '@heroicons/react/24/outline';

import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { StatsCard } from '@/components/ui/StatsCard';
import { AlertsList } from '@/components/surveillance/AlertsList';
import { TradingChart } from '@/components/charts/TradingChart';
import { RecentActivity } from '@/components/dashboard/RecentActivity';
import { ComplianceScore } from '@/components/compliance/ComplianceScore';
import { useApi } from '@/hooks/useApi';
import { useDashboardStore } from '@/store/dashboardStore';

interface DashboardStats {
  totalTrades: number;
  totalAlerts: number;
  openAlerts: number;
  complianceScore: number;
  activeUsers: number;
  todayVolume: number;
  changePercent: number;
  processingLatency: number;
}

export default function Dashboard() {
  const { stats, alerts, recentActivity, setStats, setAlerts, setRecentActivity } = useDashboardStore();
  const [loading, setLoading] = useState(true);
  const { fetchApi } = useApi();

  useEffect(() => {
    const loadDashboardData = async () => {
      try {
        setLoading(true);

        // Fetch dashboard statistics
        const [statsData, alertsData, activityData] = await Promise.all([
          fetchApi<DashboardStats>('/api/v1/dashboard/stats'),
          fetchApi('/api/v1/surveillance/alerts?limit=10&status=open'),
          fetchApi('/api/v1/audit/recent-activity?limit=20'),
        ]);

        setStats(statsData);
        setAlerts(alertsData);
        setRecentActivity(activityData);
      } catch (error) {
        console.error('Failed to load dashboard data:', error);
      } finally {
        setLoading(false);
      }
    };

    loadDashboardData();

    // Set up real-time updates
    const interval = setInterval(loadDashboardData, 30000); // Update every 30 seconds

    return () => clearInterval(interval);
  }, [fetchApi, setStats, setAlerts, setRecentActivity]);

  if (loading) {
    return (
      <DashboardLayout>
        <div className="flex items-center justify-center min-h-screen">
          <div className="animate-spin rounded-full h-32 w-32 border-b-2 border-primary-600"></div>
        </div>
      </DashboardLayout>
    );
  }

  const statsCards = [
    {
      title: 'Total Trades Today',
      value: stats?.totalTrades?.toLocaleString() || '0',
      change: `+${stats?.changePercent || 0}%`,
      changeType: 'positive' as const,
      icon: ChartBarIcon,
      color: 'blue',
    },
    {
      title: 'Active Alerts',
      value: stats?.openAlerts?.toString() || '0',
      change: `${stats?.totalAlerts || 0} total`,
      changeType: stats?.openAlerts > 10 ? 'negative' : 'neutral' as const,
      icon: ExclamationTriangleIcon,
      color: 'red',
    },
    {
      title: 'Compliance Score',
      value: `${stats?.complianceScore || 0}%`,
      change: 'Last 30 days',
      changeType: stats?.complianceScore >= 95 ? 'positive' : 'negative' as const,
      icon: ShieldCheckIcon,
      color: 'green',
    },
    {
      title: 'Processing Latency',
      value: `${stats?.processingLatency || 0}μs`,
      change: 'Average response',
      changeType: 'neutral' as const,
      icon: ClockIcon,
      color: 'purple',
    },
    {
      title: 'Active Users',
      value: stats?.activeUsers?.toString() || '0',
      change: 'Currently online',
      changeType: 'neutral' as const,
      icon: UsersIcon,
      color: 'indigo',
    },
    {
      title: 'Trading Volume',
      value: `₹${(stats?.todayVolume / 10000000)?.toFixed(1) || 0}Cr`,
      change: 'Today',
      changeType: 'positive' as const,
      icon: CurrencyDollarIcon,
      color: 'green',
    },
  ];

  return (
    <DashboardLayout>
      <div className="space-y-8">
        {/* Header */}
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-3xl font-bold tracking-tight text-gray-900">
              Surveillance Dashboard
            </h1>
            <p className="mt-2 text-sm text-gray-600">
              Real-time monitoring and compliance overview
            </p>
          </div>
          <div className="flex items-center space-x-3">
            <div className="flex items-center space-x-2 text-sm">
              <div className="w-2 h-2 bg-green-400 rounded-full animate-pulse"></div>
              <span className="text-gray-600">Live</span>
            </div>
          </div>
        </div>

        {/* Stats Cards */}
        <div className="grid grid-cols-1 gap-6 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-6">
          {statsCards.map((card, index) => (
            <motion.div
              key={card.title}
              initial={{ opacity: 0, y: 20 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.6, delay: index * 0.1 }}
            >
              <StatsCard {...card} />
            </motion.div>
          ))}
        </div>

        {/* Main Content Grid */}
        <div className="grid grid-cols-1 gap-8 lg:grid-cols-3">
          {/* Left Column - Charts and Analytics */}
          <div className="lg:col-span-2 space-y-8">
            {/* Trading Volume Chart */}
            <motion.div
              initial={{ opacity: 0, x: -20 }}
              animate={{ opacity: 1, x: 0 }}
              transition={{ duration: 0.8, delay: 0.3 }}
              className="bg-white rounded-xl shadow-soft border border-gray-200 p-6"
            >
              <div className="flex items-center justify-between mb-6">
                <h3 className="text-lg font-semibold text-gray-900">
                  Trading Volume & Patterns
                </h3>
                <select className="text-sm border-gray-300 rounded-md focus:ring-primary-500 focus:border-primary-500">
                  <option>Last 24 Hours</option>
                  <option>Last 7 Days</option>
                  <option>Last 30 Days</option>
                </select>
              </div>
              <TradingChart />
            </motion.div>

            {/* Compliance Score Overview */}
            <motion.div
              initial={{ opacity: 0, x: -20 }}
              animate={{ opacity: 1, x: 0 }}
              transition={{ duration: 0.8, delay: 0.5 }}
              className="bg-white rounded-xl shadow-soft border border-gray-200 p-6"
            >
              <h3 className="text-lg font-semibold text-gray-900 mb-6">
                Compliance Overview
              </h3>
              <ComplianceScore score={stats?.complianceScore || 0} />
            </motion.div>
          </div>

          {/* Right Column - Alerts and Activity */}
          <div className="space-y-8">
            {/* Active Alerts */}
            <motion.div
              initial={{ opacity: 0, x: 20 }}
              animate={{ opacity: 1, x: 0 }}
              transition={{ duration: 0.8, delay: 0.4 }}
              className="bg-white rounded-xl shadow-soft border border-gray-200"
            >
              <div className="px-6 py-4 border-b border-gray-200">
                <div className="flex items-center justify-between">
                  <h3 className="text-lg font-semibold text-gray-900">
                    Active Alerts
                  </h3>
                  <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-red-100 text-red-800">
                    {stats?.openAlerts || 0} Open
                  </span>
                </div>
              </div>
              <div className="p-6">
                <AlertsList alerts={alerts} compact />
              </div>
            </motion.div>

            {/* Recent Activity */}
            <motion.div
              initial={{ opacity: 0, x: 20 }}
              animate={{ opacity: 1, x: 0 }}
              transition={{ duration: 0.8, delay: 0.6 }}
              className="bg-white rounded-xl shadow-soft border border-gray-200"
            >
              <div className="px-6 py-4 border-b border-gray-200">
                <h3 className="text-lg font-semibold text-gray-900">
                  Recent Activity
                </h3>
              </div>
              <div className="p-6">
                <RecentActivity activities={recentActivity} />
              </div>
            </motion.div>
          </div>
        </div>

        {/* Performance Metrics */}
        <motion.div
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.8, delay: 0.7 }}
          className="bg-white rounded-xl shadow-soft border border-gray-200 p-6"
        >
          <h3 className="text-lg font-semibold text-gray-900 mb-6">
            System Performance
          </h3>
          <div className="grid grid-cols-1 md:grid-cols-4 gap-6">
            <div className="text-center">
              <div className="text-2xl font-bold text-green-600">99.9%</div>
              <div className="text-sm text-gray-500">Uptime</div>
            </div>
            <div className="text-center">
              <div className="text-2xl font-bold text-blue-600">1.2M</div>
              <div className="text-sm text-gray-500">Trades/sec</div>
            </div>
            <div className="text-center">
              <div className="text-2xl font-bold text-purple-600">85μs</div>
              <div className="text-sm text-gray-500">Avg Latency</div>
            </div>
            <div className="text-center">
              <div className="text-2xl font-bold text-indigo-600">50+</div>
              <div className="text-sm text-gray-500">Active Patterns</div>
            </div>
          </div>
        </motion.div>
      </div>
    </DashboardLayout>
  );
}
