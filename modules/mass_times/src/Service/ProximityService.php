<?php

namespace Drupal\mass_times\Service;

/**
 * Geographic proximity service.
 */
class ProximityService {

  /**
   * Calculate distance between two points using Haversine formula.
   *
   * @param float $lat1
   *   First point latitude.
   * @param float $lng1
   *   First point longitude.
   * @param float $lat2
   *   Second point latitude.
   * @param float $lng2
   *   Second point longitude.
   *
   * @return float
   *   Distance in kilometres.
   */
  public function distanceKm($lat1, $lng1, $lat2, $lng2) {
    $R = 6371.0;
    $lat1_r = deg2rad($lat1);
    $lat2_r = deg2rad($lat2);
    $dlat = deg2rad($lat2 - $lat1);
    $dlng = deg2rad($lng2 - $lng1);
    $a = sin($dlat / 2) ** 2 + cos($lat1_r) * cos($lat2_r) * sin($dlng / 2) ** 2;
    return $R * 2 * atan2(sqrt($a), sqrt(1 - $a));
  }

  /**
   * Get the bounding box for a given centre and radius.
   *
   * @param float $lat
   *   Centre latitude.
   * @param float $lng
   *   Centre longitude.
   * @param float $radius_km
   *   Radius in kilometres.
   *
   * @return array
   *   Array with keys: min_lat, max_lat, min_lng, max_lng.
   */
  public function getBoundingBox($lat, $lng, $radius_km) {
    // Approximate degrees per km at the given latitude.
    $lat_delta = $radius_km / 111.32;
    $lng_delta = $radius_km / (111.32 * cos(deg2rad($lat)));

    return [
      'min_lat' => $lat - $lat_delta,
      'max_lat' => $lat + $lat_delta,
      'min_lng' => $lng - $lng_delta,
      'max_lng' => $lng + $lng_delta,
    ];
  }

}
