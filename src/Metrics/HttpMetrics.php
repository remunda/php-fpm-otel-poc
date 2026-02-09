<?php

namespace App\Metrics;

use OpenTelemetry\API\Metrics\HistogramInterface;
use OpenTelemetry\API\Metrics\MeterInterface;

class HttpMetrics
{
    private static ?HttpMetrics $instance = null;

    public readonly HistogramInterface $requestDurationHistogram;

    private function __construct(MeterInterface $meter)
    {
        // Histogram for request duration (using SemConv standard metric name)
        // https://opentelemetry.io/docs/specs/semconv/http/http-metrics/#metric-httpserverrequest_duration
        $this->requestDurationHistogram = $meter->createHistogram(
            'http.server.request.duration',
            's',
            'Duration of HTTP server requests'
        );
    }

    public static function create(MeterInterface $meter): self
    {
        if (self::$instance === null) {
            self::$instance = new self($meter);
        }

        return self::$instance;
    }
}
