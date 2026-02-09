# PHP-FPM + OpenTelemetry POC

> **🇨🇿 Česká verze níže** | **🇬🇧 English version below**

---

## 🇬🇧 English

### Overview

This is a minimal Proof of Concept (POC) demonstrating:
- **Symfony 5.4** with OpenTelemetry auto-instrumentation
- **PHP-FPM** with configurable worker count
- **Grafana Alloy** as OTLP collector
- **`http.server.request.duration` histogram** metric with semantic conventions
- **K3D (k3s-in-Docker)** local Kubernetes cluster
- **Continuous load generator** for histogram data

### Known Issue: PHP-FPM Workers & Metric Cardinality

⚠️ **IMPORTANT**: PHP-FPM creates independent processes (workers). Each worker:
- Runs its own OpenTelemetry SDK instance
- Exports metrics **independently** based on `OTEL_METRIC_EXPORT_INTERVAL`
- Creates **separate time series** with unique `process.pid` attribute

**Result**: With 10 workers and 60-second export interval, you get **10 exports per minute** instead of 1, multiplying your Data Points per Minute (DPM) by the worker count.

### How to Diagnose the Problem

#### 1. Check Current Worker Count
```bash
kubectl get pods -n oteltest-local -l app=webserver-php-fpm
kubectl exec -it deployment/php-app -c php-fpm -n oteltest-local -- ps aux | grep php-fpm
```

Count the `php-fpm: pool www` processes (excluding master).

#### 2. Check Prometheus Scraping (Duplicate Metrics)
```bash
kubectl get pods -n oteltest-local -l app=webserver-php-fpm -o yaml | grep "prometheus.io/scrape"
```

If you see `prometheus.io/scrape: "true"`, Alloy is **also** scraping metrics via Prometheus, **doubling** your DPM.

#### 3. Monitor Actual Metric Volume
Check Alloy logs for export stats:
```bash
kubectl logs -f statefulset/grafana-alloy -n oteltest-local | grep "Exporting metrics"
```

Or check Grafana Cloud usage dashboard.

### Validation Steps (POC within Free Tier)

To confirm the pipeline works correctly **before scaling**:

#### Step 1: Reduce to 1 Worker
```bash
kubectl set env deployment/php-app PHP_FPM_MAX_CHILDREN=1 -n oteltest-local
kubectl rollout status deployment/php-app -n oteltest-local
```

#### Step 2: Remove Prometheus Scraping Annotation
Edit [orchestration/kubernetes/app/deployment.yaml](orchestration/kubernetes/app/deployment.yaml):
```yaml
  annotations:
    # prometheus.io/scrape: "true"  # COMMENTED OUT
    # prometheus.io/port: "9000"
```

Redeploy:
```bash
docker build -t oteltest-app:latest . && \
k3d image import oteltest-app:latest -c oteltest-local && \
kubectl rollout restart deployment/php-app -n oteltest-local
```

#### Step 3: Tighten Metric Filter (Single Metric)
Edit [orchestration/kubernetes/grafana/base/config.alloy](orchestration/kubernetes/grafana/base/config.alloy) line ~308:
```hcl
metrics {
  // Keep ONLY http.server.request.duration for POC validation
  metric = [
    "not(name == \"http.server.request.duration\")",
  ]
}
```

Update Alloy config:
```bash
kubectl create configmap alloy-config \
  --from-file=config.alloy=orchestration/kubernetes/grafana/base/config.alloy \
  -n oteltest-local --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart statefulset/grafana-alloy -n oteltest-local
```

#### Step 4: Verify Low Volume
After 5 minutes, check:
- **Expected DPM**: ~2-5 (1 worker × 1 metric × ~15s export interval × histogram buckets)
- **Grafana Cloud usage**: Should stay well within 10k free tier

### Production Recommendations

Once validated:

1. **High-cardinality attribute removal**: Alloy already drops `process.pid`, `pod`, `instance` via [transform processor](orchestration/kubernetes/grafana/base/config.alloy#L370)
2. **Aggregate at collector**: Use [interval processor](orchestration/kubernetes/grafana/base/config.alloy#L345) (already configured, 60s aggregation)
3. **Scale workers based on DPM budget**: If you need 10 workers, expect 10× metric volume
4. **Consider application-level aggregation**: Use a shared metric exporter (e.g., StatsD sidecar) instead of per-worker OTLP

### Quick Start

```bash
# Start POC cluster (uses ports 8180:80, 8543:443 to avoid conflicts)
./k3drun.sh

# Port-forward to test endpoint
kubectl port-forward svc/php-fpm 8080:8080 -n oteltest-local
curl http://localhost:8080/api/test

# Change worker count (requires rebuild)
kubectl set env deployment/php-app PHP_FPM_MAX_CHILDREN=2 -n oteltest-local

# Change load generator cadence (e.g., 10 req/s)
kubectl set env deployment/load-generator LOAD_INTERVAL=0.1 -n oteltest-local

# Port-forward Alloy UI
kubectl port-forward svc/grafana-alloy 12345:12345 -n oteltest-local
# Open http://localhost:12345

# Cleanup
k3d cluster delete oteltest-local
```

### File Structure

```
├── src/
│   ├── Controller/TestController.php     # /api/test endpoint with random latency
│   └── EventSubscriber/                  # HTTP metrics subscriber
│       └── HttpMetricsSubscriber.php
├── config/                                # Symfony config
├── web/index.php                          # Front controller
├── Dockerfile                             # PHP 8.3 + OTel extension + Symfony
├── docker-php-entrypoint                  # Generates www.conf with envsubst
├── docker/www.conf.template               # PHP-FPM pool config
├── orchestration/kubernetes/
│   ├── app/
│   │   ├── deployment.yaml                # PHP-FPM + Nginx sidecar
│   │   ├── service.yaml
│   │   ├── nginx-configmap.yaml
│   │   └── load-generator.yaml            # Busybox continuous requests
│   └── grafana/
│       └── base/config.alloy              # Alloy pipeline (OTLP → Grafana Cloud)
└── k3drun.sh                              # Cluster bootstrap + app deployment
```

