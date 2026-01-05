/**
 * @file
 * Novena navigation behavior for Divine Mercy module.
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
   * Novena navigation behavior.
   */
  Drupal.behaviors.divineMercyNovenaNavigation = {
    attach: function (context, settings) {
      once('divine-mercy-novena-nav', '#novena-navigation', context).forEach(function (navElement) {
        var dayButtons = navElement.querySelectorAll('.novena-day-button');
        var serverDay = settings.divineMercy ? settings.divineMercy.currentDay : null;
        var secondaryDay = settings.divineMercy ? settings.divineMercy.secondaryDay : null;

        // Check if the server day matches the actual current day
        var actualDay = calculateCurrentDay();
        if (serverDay && actualDay !== serverDay) {
          // Day has changed since page was cached, reload to get fresh content
          window.location.reload(true);
          return;
        }

        var currentDay = actualDay;

        // Highlight current day(s).
        dayButtons.forEach(function (button) {
          var day = parseInt(button.getAttribute('data-day'), 10);

          if (day === currentDay) {
            button.classList.add('is-current');
            button.setAttribute('aria-current', 'true');
          }

          if (day === secondaryDay) {
            button.classList.add('is-secondary');
          }

          // Add click handler for smooth scrolling if on same page.
          button.addEventListener('click', function (e) {
            // Let the default link behavior work.
            // Could add AJAX loading here if needed.
          });
        });
      });
    }
  };

})(Drupal, drupalSettings, once);
