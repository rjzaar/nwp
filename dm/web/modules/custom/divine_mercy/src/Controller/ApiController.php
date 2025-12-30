<?php

namespace Drupal\divine_mercy\Controller;

use Drupal\Core\Controller\ControllerBase;
use Drupal\divine_mercy\Service\NovenaService;
use Symfony\Component\DependencyInjection\ContainerInterface;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;

/**
 * API controller for Divine Mercy AJAX endpoints.
 */
class ApiController extends ControllerBase {

  /**
   * The novena service.
   *
   * @var \Drupal\divine_mercy\Service\NovenaService
   */
  protected $novenaService;

  /**
   * Constructs an ApiController object.
   *
   * @param \Drupal\divine_mercy\Service\NovenaService $novena_service
   *   The novena service.
   */
  public function __construct(NovenaService $novena_service) {
    $this->novenaService = $novena_service;
  }

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container) {
    return new static(
      $container->get('divine_mercy.novena_service')
    );
  }

  /**
   * Saves font size preference.
   *
   * @param \Symfony\Component\HttpFoundation\Request $request
   *   The request object.
   *
   * @return \Symfony\Component\HttpFoundation\JsonResponse
   *   JSON response with success status.
   */
  public function saveFontSize(Request $request) {
    $content = json_decode($request->getContent(), TRUE);
    $fontSize = $content['fontSize'] ?? 100;

    // Font size is stored client-side in localStorage.
    // This endpoint is for future server-side storage if needed.
    return new JsonResponse([
      'success' => TRUE,
      'fontSize' => $fontSize,
    ]);
  }

  /**
   * Gets the current novena day.
   *
   * @return \Symfony\Component\HttpFoundation\JsonResponse
   *   JSON response with current day info.
   */
  public function getCurrentDay() {
    $currentDay = $this->novenaService->getCurrentDayNumber();
    $secondaryDay = $this->novenaService->getSecondaryDayNumber();

    $schedule = [];
    for ($i = 1; $i <= 9; $i++) {
      $schedule[$i] = [
        'day' => $i,
        'theme' => $this->novenaService->getDayTheme($i),
        'weekday' => $this->novenaService->getWeekdayForDay($i),
        'isCurrent' => ($i === $currentDay),
        'isSecondary' => ($i === $secondaryDay),
      ];
    }

    return new JsonResponse([
      'currentDay' => $currentDay,
      'secondaryDay' => $secondaryDay,
      'isNovenaActive' => $currentDay > 0,
      'schedule' => $schedule,
    ]);
  }

}
