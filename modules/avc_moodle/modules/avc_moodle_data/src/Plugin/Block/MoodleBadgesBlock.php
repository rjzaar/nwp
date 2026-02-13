<?php

namespace Drupal\avc_moodle_data\Plugin\Block;

use Drupal\Core\Block\BlockBase;
use Drupal\Core\Plugin\ContainerFactoryPluginInterface;
use Symfony\Component\DependencyInjection\ContainerInterface;

/**
 * Provides a 'Moodle Badges' block.
 *
 * @Block(
 *   id = "moodle_badges_block",
 *   admin_label = @Translation("Moodle Badges"),
 *   category = @Translation("AVC Moodle")
 * )
 */
class MoodleBadgesBlock extends BlockBase implements ContainerFactoryPluginInterface {

  protected $moodleData;

  public static function create(ContainerInterface $container, array $configuration, $plugin_id, $plugin_definition) {
    $instance = new static($configuration, $plugin_id, $plugin_definition);
    $instance->moodleData = $container->get('avc_moodle_data.moodle_data');
    return $instance;
  }

  public function build() {
    $user = \Drupal::routeMatch()->getParameter('user');
    if (!$user) {
      return [];
    }

    // Get Moodle user ID (would need mapping).
    $badges = $this->moodleData->getUserBadges($user->id());

    return [
      '#theme' => 'avc_moodle_badges',
      '#badges' => $badges,
      '#cache' => [
        'max-age' => 3600,
        'contexts' => ['url.path'],
      ],
    ];
  }

}
