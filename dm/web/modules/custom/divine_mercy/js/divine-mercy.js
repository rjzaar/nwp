/**
 * @file
 * Divine Mercy main JavaScript behaviors.
 */

(function (Drupal, drupalSettings, once) {
  'use strict';

  /**
   * Initialize Divine Mercy module.
   */
  Drupal.behaviors.divineMercy = {
    attach: function (context, settings) {
      once('divine-mercy-init', '.divine-mercy-chaplet, .divine-mercy-novena-day', context).forEach(function (element) {
        // Apply saved font size on page load.
        var savedSize = localStorage.getItem('divineMercyFontSize');
        if (savedSize) {
          document.documentElement.style.setProperty('--prayer-font-size', savedSize + '%');
        }
      });
    }
  };

})(Drupal, drupalSettings, once);
