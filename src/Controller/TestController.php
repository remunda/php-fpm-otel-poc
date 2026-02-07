<?php

namespace App\Controller;

use Symfony\Bundle\FrameworkBundle\Controller\AbstractController;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\Routing\Annotation\Route;

class TestController extends AbstractController
{
    /**
     * Test endpoint that simulates variable response times.
     * Generates data for http.server.request.duration histogram.
     *
     * Distribution:
     *  - 70% fast requests: 5-50ms
     *  - 20% medium requests: 50-200ms
     *  - 8% slow requests: 200-500ms
     *  - 2% very slow requests: 500-2000ms
     */
    #[Route('/api/test', name: 'api_test', methods: ['GET'])]
    public function test(): JsonResponse
    {
        $roll = random_int(1, 100);

        if ($roll <= 70) {
            $sleepMs = random_int(5, 50);
        } elseif ($roll <= 90) {
            $sleepMs = random_int(50, 200);
        } elseif ($roll <= 98) {
            $sleepMs = random_int(200, 500);
        } else {
            $sleepMs = random_int(500, 2000);
        }

        usleep($sleepMs * 1000);

        return $this->json([
            'status' => 'ok',
            'sleep_ms' => $sleepMs,
            'timestamp' => time(),
            'worker_pid' => getmypid(),
        ]);
    }

    #[Route('/health', name: 'health', methods: ['GET'])]
    public function health(): JsonResponse
    {
        return $this->json(['status' => 'healthy']);
    }
}
