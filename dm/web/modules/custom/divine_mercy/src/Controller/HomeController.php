<?php

namespace Drupal\divine_mercy\Controller;

use Drupal\Core\Controller\ControllerBase;

/**
 * Controller for the Divine Mercy home page.
 */
class HomeController extends ControllerBase {

  /**
   * Displays the Divine Mercy home page.
   *
   * @return array
   *   A render array.
   */
  public function display() {
    $build = [
      '#theme' => 'divine_mercy_home',
      '#attached' => [
        'library' => [
          'divine_mercy/divine-mercy',
        ],
      ],
      '#cache' => [
        'contexts' => ['languages'],
      ],
    ];

    return $build;
  }

}
