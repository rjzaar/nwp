/**
 * @file
 * Novena navigation behavior for Divine Mercy module.
 */

(function (Drupal, drupalSettings, once) {
  'use strict';

  /**
   * Get today's date as a string (YYYY-MM-DD) for comparison.
   */
  function getToday() {
    var now = new Date();
    return now.getFullYear() + '-' +
           String(now.getMonth() + 1).padStart(2, '0') + '-' +
           String(now.getDate()).padStart(2, '0');
  }

  /**
   * Calculate days between two date strings.
   */
  function daysBetween(dateStr1, dateStr2) {
    var date1 = new Date(dateStr1);
    var date2 = new Date(dateStr2);
    var diffTime = date2 - date1;
    return Math.floor(diffTime / (1000 * 60 * 60 * 24));
  }

  /**
   * Get the user's current novena day based on their stored progress.
   * Returns null if no active novena.
   */
  function getUserNovenaDay() {
    var startDate = localStorage.getItem('divineMercyNovenaStart');
    var lastAccessDate = localStorage.getItem('divineMercyLastAccess');
    var storedDay = localStorage.getItem('divineMercyNovenaDay');

    if (!startDate || !storedDay) {
      return null;
    }

    var today = getToday();
    var currentDay = parseInt(storedDay, 10);

    // If last access was before today, advance the day
    if (lastAccessDate && lastAccessDate < today) {
      var daysElapsed = daysBetween(lastAccessDate, today);
      currentDay = currentDay + daysElapsed;

      // If past day 9, novena is complete - could restart or return null
      if (currentDay > 9) {
        // Start a new novena
        localStorage.setItem('divineMercyNovenaStart', today);
        localStorage.setItem('divineMercyNovenaDay', '1');
        localStorage.setItem('divineMercyLastAccess', today);
        return 1;
      }

      // Update stored day
      localStorage.setItem('divineMercyNovenaDay', currentDay.toString());
    }

    // Update last access
    localStorage.setItem('divineMercyLastAccess', today);

    return currentDay;
  }

  /**
   * Start a new novena for the user.
   */
  function startNovena(day) {
    var today = getToday();
    localStorage.setItem('divineMercyNovenaStart', today);
    localStorage.setItem('divineMercyNovenaDay', day.toString());
    localStorage.setItem('divineMercyLastAccess', today);
  }

  /**
   * Novena navigation behavior - handles the overview page.
   */
  Drupal.behaviors.divineMercyNovenaNavigation = {
    attach: function (context, settings) {
      once('divine-mercy-novena-nav', '#novena-navigation', context).forEach(function (navElement) {
        var dayButtons = navElement.querySelectorAll('.novena-day-button');
        var secondaryDay = settings.divineMercy ? settings.divineMercy.secondaryDay : null;

        // Check if user has an active novena and redirect to their current day
        var userDay = getUserNovenaDay();
        if (userDay && window.location.pathname === '/novena') {
          // Redirect to their current day
          window.location.href = '/novena/day/' + userDay;
          return;
        }

        // Highlight current day(s).
        dayButtons.forEach(function (button) {
          var day = parseInt(button.getAttribute('data-day'), 10);

          if (userDay && day === userDay) {
            button.classList.add('is-current');
            button.setAttribute('aria-current', 'true');
          }

          if (day === secondaryDay) {
            button.classList.add('is-secondary');
          }

          // When user clicks a day, start/update their novena
          button.addEventListener('click', function (e) {
            startNovena(day);
          });
        });
      });
    }
  };

  /**
   * Track novena day visits.
   */
  Drupal.behaviors.divineMercyNovenaDayTracker = {
    attach: function (context, settings) {
      once('divine-mercy-day-tracker', '.divine-mercy-novena-day', context).forEach(function (element) {
        // Extract day number from URL or page
        var pathMatch = window.location.pathname.match(/\/novena\/day\/(\d+)/);
        if (pathMatch) {
          var visitedDay = parseInt(pathMatch[1], 10);
          var storedDay = localStorage.getItem('divineMercyNovenaDay');

          // If no novena started, start one
          if (!storedDay) {
            startNovena(visitedDay);
          } else {
            // Update last access date
            localStorage.setItem('divineMercyLastAccess', getToday());
          }
        }
      });
    }
  };

})(Drupal, drupalSettings, once);
