/**
 * @file
 * Divine Mercy main JavaScript behaviors.
 */

(function (Drupal, drupalSettings, once) {
  'use strict';

  /**
   * Calculate the current novena day based on the day of week.
   * Friday = Day 1, Saturday = Day 2, Sunday = Day 3, etc.
   */
  function calculateCurrentDay() {
    var dayOfWeek = new Date().getDay(); // 0 = Sunday, 6 = Saturday
    var dayMapping = {
      5: 1, // Friday
      6: 2, // Saturday
      0: 3, // Sunday
      1: 4, // Monday
      2: 5, // Tuesday
      3: 6, // Wednesday
      4: 7  // Thursday
    };
    return dayMapping[dayOfWeek] || 1;
  }

  /**
   * Initialize Divine Mercy module.
   */
  Drupal.behaviors.divineMercy = {
    attach: function (context, settings) {
      once('divine-mercy-init', '.divine-mercy-chaplet, .divine-mercy-novena-day', context).forEach(function (element) {
        // Check if the server day matches the actual current day
        var serverDay = settings.divineMercy ? settings.divineMercy.currentDay : null;
        var actualDay = calculateCurrentDay();
        if (serverDay && actualDay !== serverDay) {
          // Day has changed since page was cached, reload to get fresh content
          window.location.reload(true);
          return;
        }

        // Apply saved font size on page load.
        var savedSize = localStorage.getItem('divineMercyFontSize');
        if (savedSize) {
          document.documentElement.style.setProperty('--prayer-font-size', savedSize + '%');
        }
      });
    }
  };

})(Drupal, drupalSettings, once);
