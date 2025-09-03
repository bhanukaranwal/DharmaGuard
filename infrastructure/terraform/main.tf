# DharmaGuard Infrastructure - Main Terraform Configuration
# Production-ready infrastructure for enterprise deployment

terraform {
  required_version = ">= 1.7.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.24"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "s3" {
    bucket         = "dharmaguard-terraform-state"
    key            = "infrastructure/terraform.tfstate"
    region         = "ap-south-1"
    encrypt        = true
    dynamodb_table = "dharmaguard-terraform-locks"
  }
}

# Configure providers
provider "aws" {
  region = var.aws_region
  
  default_tags {
    tags = {
      Project     = "DharmaGuard"
      Environment = var.environment
      ManagedBy   = "Terraform"
      CostCenter  = "Engineering"
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

# Data sources
data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

# Local values
locals {
  cluster_name = "${var.project_name}-${var.environment}"
  
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Owner       = "DharmaGuard-Team"
  }
  
  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)
}

# Random password for databases
resource "random_password" "database_password" {
  length  = 32
  special = true
}

# VPC Module
module "vpc" {
  source = "./modules/vpc"
  
  name               = local.cluster_name
  cidr               = local.vpc_cidr
  azs                = local.azs
  private_subnets    = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
  database_subnets   = ["10.0.201.0/24", "10.0.202.0/24", "10.0.203.0/24"]
  
  enable_nat_gateway   = true
  enable_vpn_gateway   = false
  enable_dns_hostnames = true
  enable_dns_support   = true
  
  # Kubernetes integration
  public_subnet_tags = {
    "kubernetes.io/role/elb"                        = "1"
    "kubernetes.io/cluster/${local.cluster_name}"   = "owned"
  }
  
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"               = "1"
    "kubernetes.io/cluster/${local.cluster_name}"   = "owned"
  }
  
  tags = local.common_tags
}

# EKS Cluster
module "eks" {
  source = "./modules/eks"
  
  cluster_name    = local.cluster_name
  cluster_version = "1.29"
  
  vpc_id                   = module.vpc.vpc_id
  subnet_ids              = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets
  
  # OIDC Provider
  enable_irsa = true
  
  # Cluster endpoint access
  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = true
  cluster_endpoint_public_access_cidrs = var.allowed_cidr_blocks
  
  # Cluster encryption
  cluster_encryption_config = [{
    provider_key_arn = module.kms.key_arn
    resources        = ["secrets"]
  }]
  
  # Node groups
  node_groups = {
    surveillance_engines = {
      desired_capacity = 3
      max_capacity     = 10
      min_capacity     = 2
      
      instance_types = ["c5.4xlarge"]  # CPU optimized for surveillance engine
      capacity_type  = "ON_DEMAND"
      
      k8s_labels = {
        Environment = var.environment
        NodeGroup   = "surveillance-engines"
        Workload    = "compute-intensive"
      }
      
      k8s_taints = [{
        key    = "workload"
        value  = "surveillance"
        effect = "NO_SCHEDULE"
      }]
    }
    
    general_workloads = {
      desired_capacity = 6
      max_capacity     = 20
      min_capacity     = 3
      
      instance_types = ["m5.2xlarge"]
      capacity_type  = "SPOT"
      
      k8s_labels = {
        Environment = var.environment
        NodeGroup   = "general-workloads"
        Workload    = "general"
      }
    }
  }
  
  # Fargate profiles for serverless workloads
  fargate_profiles = {
    ml_platform = {
      selectors = [{
        namespace = "dharmaguard-ml"
        labels = {
          workload = "ml-training"
        }
      }]
    }
  }
  
  tags = local.common_tags
}

# RDS for PostgreSQL
module "rds" {
  source = "./modules/rds"
  
  identifier = "${local.cluster_name}-postgres"
  
  engine         = "postgres"
  engine_version = "16.1"
  instance_class = "db.r5.2xlarge"
  
  allocated_storage     = 1000
  max_allocated_storage = 5000
  storage_type         = "gp3"
  storage_encrypted    = true
  kms_key_id          = module.kms.key_arn
  
  db_name  = "dharmaguard"
  username = "dharmaguard"
  password = random_password.database_password.result
  port     = "5432"
  
  vpc_security_group_ids = [module.security_groups.database_sg_id]
  db_subnet_group_name   = module.vpc.database_subnet_group
  
  backup_retention_period = 30
  backup_window          = "03:00-04:00"
  maintenance_window     = "sun:04:00-sun:05:00"
  
  # Multi-AZ deployment for high availability
  multi_az = true
  
  # Read replicas for read scaling
  read_replica_count = 2
  
  # Performance monitoring
  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_enhanced_monitoring.arn
  
  # Performance Insights
  performance_insights_enabled = true
  performance_insights_kms_key_id = module.kms.key_arn
  
  deletion_protection = true
  
  tags = local.common_tags
}

# ElastiCache for Redis
module "elasticache" {
  source = "./modules/elasticache"
  
  cluster_id = "${local.cluster_name}-redis"
  
  engine         = "redis"
  engine_version = "7.0"
  node_type      = "cache.r6g.2xlarge"
  
  num_cache_nodes = 3
  port           = 6379
  
  subnet_group_name  = module.vpc.elasticache_subnet_group
  security_group_ids = [module.security_groups.elasticache_sg_id]
  
  # Redis specific configurations
  parameter_group_name = aws_elasticache_parameter_group.redis.name
  
  # Backup and maintenance
  snapshot_retention_limit = 7
  snapshot_window         = "03:00-05:00"
  maintenance_window      = "sun:05:00-sun:07:00"
  
  # Encryption
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                = random_password.redis_auth_token.result
  
  tags = local.common_tags
}

# MSK for Kafka
module "msk" {
  source = "./modules/msk"
  
  cluster_name = "${local.cluster_name}-kafka"
  
  kafka_version   = "2.8.1"
  number_of_broker_nodes = 6
  instance_type   = "kafka.m5.2xlarge"
  
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets
  
  # Security
  client_authentication = {
    tls = {
      certificate_authority_arns = []
    }
    sasl = {
      scram = true
      iam   = true
    }
  }
  
  # Encryption
  encryption_in_transit_client_broker = "TLS"
  encryption_in_transit_in_cluster    = true
  
  # Storage
  storage_mode   = "LOCAL"
  volume_size    = 1000
  volume_type    = "gp3"
  
  # Monitoring
  enhanced_monitoring = "PER_TOPIC_PER_BROKER"
  
  tags = local.common_tags
}

# KMS for encryption
module "kms" {
  source = "./modules/kms"
  
  description = "DharmaGuard encryption key"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow EKS Service"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })
  
  tags = local.common_tags
}

# Security Groups
module "security_groups" {
  source = "./modules/security_groups"
  
  vpc_id = module.vpc.vpc_id
  
  tags = local.common_tags
}

# Application Load Balancer
module "alb" {
  source = "./modules/alb"
  
  name = local.cluster_name
  
  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.public_subnets
  
  security_groups = [module.security_groups.alb_sg_id]
  
  # SSL certificate
  certificate_arn = module.acm.certificate_arn
  
  tags = local.common_tags
}

# ACM Certificate
module "acm" {
  source = "./modules/acm"
  
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  
  zone_id = data.aws_route53_zone.main.zone_id
  
  tags = local.common_tags
}

# Route53 DNS
data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

# CloudWatch Log Groups
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${local.cluster_name}/cluster"
  retention_in_days = 30
  kms_key_id        = module.kms.key_arn
  
  tags = local.common_tags
}

# IAM Role for RDS Enhanced Monitoring
resource "aws_iam_role" "rds_enhanced_monitoring" {
  name = "${local.cluster_name}-rds-monitoring-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "monitoring.rds.amazonaws.com"
        }
      }
    ]
  })
  
  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring" {
  role       = aws_iam_role.rds_enhanced_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# Redis auth token
resource "random_password" "redis_auth_token" {
  length  = 32
  special = false
}

# ElastiCache parameter group
resource "aws_elasticache_parameter_group" "redis" {
  family = "redis7.x"
  name   = "${local.cluster_name}-redis-params"
  
  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
  }
  
  tags = local.common_tags
}

# Outputs
output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data"
  value       = module.eks.cluster_certificate_authority_data
}

output "database_endpoint" {
  description = "RDS instance endpoint"
  value       = module.rds.db_instance_endpoint
  sensitive   = true
}

output "database_password" {
  description = "Database password"
  value       = random_password.database_password.result
  sensitive   = true
}

output "redis_endpoint" {
  description = "ElastiCache Redis endpoint"
  value       = module.elasticache.cache_cluster_address
}

output "kafka_bootstrap_brokers" {
  description = "MSK Kafka bootstrap brokers"
  value       = module.msk.bootstrap_brokers_tls
}

output "load_balancer_dns" {
  description = "Application Load Balancer DNS name"
  value       = module.alb.dns_name
}
