# Project Summary

## Overview

AWS DevOps Agent Workshop - EKS Sample. A hands-on workshop that demonstrates the investigation capabilities of AWS DevOps Agent by deploying a microservices retail store application on Amazon EKS, injecting faults, and using the AI-powered agent to diagnose issues.

## Architecture

A microservices e-commerce application ("Retail Store") deployed on Amazon EKS (v1.34) with EKS Auto Mode:

| Service | Language | Backend |
|---------|----------|---------|
| UI | Java | - |
| Catalog | Go | Aurora MySQL |
| Carts | Java | DynamoDB |
| Orders | Java | Aurora PostgreSQL + RabbitMQ |
| Checkout | Node.js | Redis (ElastiCache) |

### Infrastructure (Terraform-managed)

- Amazon EKS cluster in VPC with public/private subnets across 3 AZs
- Amazon Aurora MySQL & PostgreSQL (RDS)
- Amazon DynamoDB
- Amazon MQ (RabbitMQ)
- Amazon ElastiCache (Redis)
- CloudWatch Container Insights with Application Signals
- Amazon Managed Prometheus
- Optional: Amazon Managed Grafana (requires AWS SSO)
- Network Flow Monitoring Agent addon

All resources are tagged `devopsagent = "true"` for automatic discovery.

## Repository Structure

```
├── terraform/
│   ├── deploy.sh              # One-click deployment (~25-30 min)
│   ├── destroy.sh             # Full cleanup including auto-provisioned resources
│   ├── eks/
│   │   ├── default/           # Main Terraform config (EKS, VPC, dependencies)
│   │   └── minimal/           # Minimal deployment variant
│   └── lib/
│       ├── dependencies/      # RDS, DynamoDB, ElastiCache, MQ modules
│       ├── eks/               # EKS cluster, observability, ADOT, Istio
│       ├── images/            # Container image references
│       ├── tags/              # Resource tagging
│       └── vpc/               # VPC networking
├── fault-injection/
│   ├── inject-catalog-latency.sh      # Lab 1: CPU stress + latency sidecar
│   ├── inject-cart-memory-leak.sh     # Lab 2: OOMKill via memory leak sidecar
│   ├── inject-rds-sg-block.sh         # Lab 3: Remove RDS security group rules
│   ├── inject-dynamodb-stress.sh      # Lab 4: DynamoDB throttling via load
│   ├── inject-network-partition.sh    # Lab 5: NetworkPolicy blocks UI ingress
│   ├── rollback-*.sh                  # Corresponding rollback scripts
│   └── lib/verify-functions.sh        # Shared verification helpers
└── docs/
    ├── features.md            # App features (theming, chat bot, topology)
    ├── images/                # Architecture diagrams and screenshots
    └── diagrams.drawio.xml    # Source diagrams
```

## Fault Injection Labs

Five progressive labs that break things and use AWS DevOps Agent to investigate:

1. **Catalog Latency** - CPU stress sidecar + reduced CPU limits cause throttling
2. **Cart Memory Leak** - Memory leak sidecar triggers OOMKill / CrashLoopBackOff
3. **RDS Security Group Block** - Removes inbound rules; services can't reach databases
4. **DynamoDB Stress** - Kubernetes Job floods DynamoDB, causing throttling
5. **Network Partition** - NetworkPolicy blocks all ingress to UI pods

Each lab follows: Inject -> Observe -> Investigate with Agent -> Identify Root Cause -> Rollback.

## Key Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `CLUSTER_NAME` | `retail-store` | EKS cluster name |
| `AWS_REGION` | `us-east-1` | Deployment region |
| `ENABLE_GRAFANA` | `false` | Amazon Managed Grafana |
| `opentelemetry_enabled` | `false` | ADOT collector |
| `istio_enabled` | `false` | Istio service mesh |

## Prerequisites

- AWS CLI (configured with credentials)
- Terraform
- kubectl
- Helm

## Quick Commands

```bash
# Deploy
./terraform/deploy.sh

# Run a fault injection lab
cd fault-injection && ./inject-catalog-latency.sh

# Rollback
./fault-injection/rollback-catalog.sh

# Destroy everything
./terraform/destroy.sh
```

## License

MIT-0
