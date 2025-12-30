<?php

/**
 * @file
 * NWP Rector Configuration Template.
 *
 * Copy this to your site's root directory.
 *
 * Usage:
 *   ddev exec vendor/bin/rector process --dry-run
 *   ddev exec vendor/bin/rector process
 */

declare(strict_types=1);

use Rector\Config\RectorConfig;
use Rector\Php80\Rector\Class_\ClassPropertyAssignToConstructorPromotionRector;
use Rector\Php81\Rector\Property\ReadOnlyPropertyRector;
use Rector\Set\ValueObject\SetList;
use Rector\TypeDeclaration\Rector\Property\TypedPropertyFromAssignsRector;
use DrupalRector\Set\Drupal10SetList;

return static function (RectorConfig $rectorConfig): void {
    // Paths to analyze
    $rectorConfig->paths([
        __DIR__ . '/web/modules/custom',
        __DIR__ . '/web/themes/custom',
    ]);

    // Skip these paths
    $rectorConfig->skip([
        __DIR__ . '/web/modules/custom/*/tests/*',
        __DIR__ . '/web/themes/custom/*/node_modules/*',
    ]);

    // PHP version features
    $rectorConfig->phpVersion(80200); // PHP 8.2

    // Import short class names
    $rectorConfig->importNames();
    $rectorConfig->importShortClasses(false);

    // Enable parallel processing
    $rectorConfig->parallel();

    // PHP upgrade sets
    $rectorConfig->sets([
        SetList::PHP_82,
        SetList::CODE_QUALITY,
        SetList::DEAD_CODE,
        SetList::TYPE_DECLARATION,
    ]);

    // Drupal-specific sets (requires drupal-rector package)
    // Uncomment after: composer require --dev palantirnet/drupal-rector
    // $rectorConfig->sets([
    //     Drupal10SetList::DRUPAL_10,
    // ]);

    // Individual rules
    $rectorConfig->rules([
        // Constructor property promotion (PHP 8.0)
        ClassPropertyAssignToConstructorPromotionRector::class,
        // Typed properties from assignments
        TypedPropertyFromAssignsRector::class,
    ]);

    // Skip specific rules that may cause issues
    $rectorConfig->skip([
        // ReadOnly properties can break Drupal's serialization
        ReadOnlyPropertyRector::class,
    ]);

    // Caching for faster subsequent runs
    $rectorConfig->cacheDirectory(__DIR__ . '/.rector-cache');
};
