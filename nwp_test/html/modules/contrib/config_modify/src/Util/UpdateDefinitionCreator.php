<?php

namespace Drupal\config_modify\Util;

/**
 * Provides tools to create the actions for an update definition.
 */
class UpdateDefinitionCreator {

  /**
   * Check whether two arrays are the same.
   *
   * @param array $a
   *   The value to compare to.
   * @param array $b
   *   The value to compare.
   * @param array|null $ignore
   *   Keys to ignore at the top level.
   *
   * @return bool
   *   Whether the arrays are equal.
   */
  public function isSame(array $a, array $b, ?array $ignore = NULL) : bool {
    return $this->produceDiff($a, $b, $ignore) === [];
  }

  /**
   * Produce the update_actions from a Config Update Definition for two arrays.
   *
   * @param array $from
   *   The start values for the array.
   * @param array $to
   *   The expected end result of the array.
   * @param array|null $ignore
   *   Keys to ignore at the top level.
   *
   * @return array{ add?: array, change?: array, delete?: array }
   *   The update actions needed to go from $from to $to. Empty if the two
   *   arrays are identical.
   */
  public function produceDiff(array $from, array $to, ?array $ignore = NULL) : array {
    if ($ignore !== NULL) {
      $from = array_filter($from, fn ($k) => !in_array($k, $ignore, TRUE), ARRAY_FILTER_USE_KEY);
      $to = array_filter($to, fn ($k) => !in_array($k, $ignore, TRUE), ARRAY_FILTER_USE_KEY);
    }

    $added_keys = array_diff(array_keys($to), array_keys($from));
    $removed_keys = array_diff(array_keys($from), array_keys($to));
    $intersecting_keys = array_intersect(array_keys($from), array_keys($to));

    $operations = [
      'add' => [],
      'change' => [],
      'delete' => [],
    ];

    foreach ($added_keys as $key) {
      $operations['add'][$key] = $to[$key];
    }

    foreach ($removed_keys as $key) {
      $operations['delete'][$key] = [];
    }

    foreach ($intersecting_keys as $key) {
      if ($from[$key] === $to[$key]) {
        continue;
      }

      if (!is_array($from[$key]) || !is_array($to[$key])) {
        $operations['change'][$key] = $to[$key];
        continue;
      }

      if (array_is_list($from[$key]) && array_is_list($to[$key])) {
        $added = array_diff($to[$key], $from[$key]);
        $removed = array_diff($from[$key], $to[$key]);

        if ($added !== []) {
          $operations['add'][$key] = array_values($added);
        }
        if ($removed !== []) {
          $operations['delete'][$key] = array_values($removed);
        }

        continue;
      }
      $nested_operations = $this->produceDiff($from[$key], $to[$key]);

      if (isset($nested_operations['add'])) {
        $operations['add'][$key] = $nested_operations['add'];
      }
      if (isset($nested_operations['change'])) {
        $operations['change'][$key] = $nested_operations['change'];
      }
      if (isset($nested_operations['delete'])) {
        $operations['delete'][$key] = $nested_operations['delete'];
      }
    }

    if ($operations['add'] === []) {
      unset($operations['add']);
    }
    if ($operations['change'] === []) {
      unset($operations['change']);
    }
    if ($operations['delete'] === []) {
      unset($operations['delete']);
    }

    return $operations;
  }

}
