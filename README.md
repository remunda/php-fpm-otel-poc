# PHP-FPM + OpenTelemetry: `OTEL_METRIC_EXPORT_INTERVAL` is ignored

POC demonstrating that `OTEL_METRIC_EXPORT_INTERVAL` has no effect with the OpenTelemetry PHP SDK under PHP-FPM. Metrics are exported on **every request** instead of at the configured interval, with no aggregation.

## Root Causes

1. **`OTEL_METRIC_EXPORT_INTERVAL` is not implemented** — [`MetricExporterFactory.php` (line ~46)](https://github.com/open-telemetry/opentelemetry-php/blob/main/src/Contrib/Otlp/MetricExporterFactory.php) has it as a `@todo`. The env var is silently ignored.

2. **PHP-FPM destroys MeterProvider on every request** — `ShutdownHandler` calls `MeterProvider::shutdown()` via `register_shutdown_function()`, which in FPM fires at the end of each request. This force-exports, closes the reader, and a new MeterProvider is created on the next request.

**Result**: every export has `Count: 1`, export rate equals request rate, and the interval setting does nothing.

## Consequence

Without SDK-side aggregation, the collector (Alloy / OTel Collector) must aggregate per-request payloads — at high CPU and memory cost. At 100 req/s with 8 FPM workers, the collector receives **800 OTLP exports/sec**, each with full histogram buckets. This is O(N) work that should happen once per interval in the app.

## Run

```bash
./k3drun.sh                          # start K3D cluster + deploy app + Alloy
kubectl port-forward svc/php-fpm 8080:8080 -n oteltest-local
curl http://localhost:8080/api/test   # trigger a request
kubectl logs -f statefulset/grafana-alloy -n oteltest-local  # observe per-request exports
k3d cluster delete oteltest-local     # cleanup
```

