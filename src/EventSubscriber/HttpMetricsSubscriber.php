<?php

namespace App\EventSubscriber;

use App\Metrics\HttpMetrics;
use OpenTelemetry\SemConv\TraceAttributes;
use Symfony\Component\EventDispatcher\EventSubscriberInterface;
use Symfony\Component\HttpKernel\Event\RequestEvent;
use Symfony\Component\HttpKernel\Event\ResponseEvent;
use Symfony\Component\HttpKernel\KernelEvents;

class HttpMetricsSubscriber implements EventSubscriberInterface
{
    private array $requestStartTimes = [];

    public function __construct(
        private readonly HttpMetrics $httpMetrics,
    ) {
    }

    public static function getSubscribedEvents(): array
    {
        return [
            KernelEvents::REQUEST => ['onKernelRequest', 1024],
            KernelEvents::RESPONSE => ['onKernelResponse', -1024],
        ];
    }

    public function onKernelRequest(RequestEvent $event): void
    {
        if (!$event->isMainRequest()) {
            return;
        }

        $request = $event->getRequest();
        $requestId = spl_object_id($request);
        $this->requestStartTimes[$requestId] = microtime(true);
    }

    public function onKernelResponse(ResponseEvent $event): void
    {
        if (!$event->isMainRequest()) {
            return;
        }

        $request = $event->getRequest();
        $response = $event->getResponse();
        $requestId = spl_object_id($request);

        if (!isset($this->requestStartTimes[$requestId])) {
            return;
        }

        $startTime = $this->requestStartTimes[$requestId];
        $duration = microtime(true) - $startTime;
        unset($this->requestStartTimes[$requestId]);

        // Record histogram with semantic convention attributes
        $attributes = [
            TraceAttributes::HTTP_REQUEST_METHOD => $request->getMethod(),
            TraceAttributes::HTTP_RESPONSE_STATUS_CODE => $response->getStatusCode(),
            TraceAttributes::URL_SCHEME => $request->getScheme(),
            TraceAttributes::NETWORK_PROTOCOL_VERSION => $request->getProtocolVersion(),
        ];

        // Add route if available
        if ($route = $request->attributes->get('_route')) {
            $attributes[TraceAttributes::HTTP_ROUTE] = $route;
        }

        $this->httpMetrics->requestDurationHistogram->record($duration, $attributes);

        error_log('onKernelResponse requestDurationHistogram ID: ' . spl_object_id($this->httpMetrics->requestDurationHistogram));

    }
}
