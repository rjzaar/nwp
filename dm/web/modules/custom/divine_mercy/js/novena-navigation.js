/**
 * @file
 * Novena navigation behavior for Divine Mercy module.
 */

(function (Drupal, drupalSettings, once) {
  'use strict';

  /**
   * Novena navigation behavior.
   */
  Drupal.behaviors.divineMercyNovenaNavigation = {
    attach: function (context, settings) {
      once('divine-mercy-novena-nav', '#novena-navigation', context).forEach(function (navElement) {
        var dayButtons = navElement.querySelectorAll('.novena-day-button');
        var currentDay = settings.divineMercy ? settings.divineMercy.currentDay : null;
        var secondaryDay = settings.divineMercy ? settings.divineMercy.secondaryDay : null;

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
