/**
 * @file
 * Font size control behavior for Divine Mercy module.
 */

(function (Drupal, drupalSettings, once) {
  'use strict';

  /**
   * Font size control behavior.
   */
  Drupal.behaviors.divineMercyFontSize = {
    attach: function (context, settings) {
      once('divine-mercy-font-size', '#font-size-control', context).forEach(function (controlElement) {
        var slider = controlElement.querySelector('#font-size-slider');
        var valueDisplay = controlElement.querySelector('#font-size-value');
        var decreaseBtn = controlElement.querySelector('.font-size-decrease');
        var increaseBtn = controlElement.querySelector('.font-size-increase');

        if (!slider) {
          return;
        }

        // Initialize from localStorage or default.
        var savedSize = localStorage.getItem('divineMercyFontSize');
        var defaultSize = settings.divineMercy ? settings.divineMercy.defaultFontSize : 100;
        var currentSize = savedSize ? parseInt(savedSize, 10) : defaultSize;

        // Set initial values.
        slider.value = currentSize;
        updateFontSize(currentSize);

        // Slider input handler.
        slider.addEventListener('input', function () {
          var size = parseInt(this.value, 10);
          updateFontSize(size);
        });

        // Slider change handler (for saving).
        slider.addEventListener('change', function () {
          var size = parseInt(this.value, 10);
          saveFontSize(size);
        });

        // Decrease button.
        if (decreaseBtn) {
          decreaseBtn.addEventListener('click', function () {
            var size = Math.max(parseInt(slider.min, 10), parseInt(slider.value, 10) - 10);
            slider.value = size;
            updateFontSize(size);
            saveFontSize(size);
          });
        }

        // Increase button.
        if (increaseBtn) {
          increaseBtn.addEventListener('click', function () {
            var size = Math.min(parseInt(slider.max, 10), parseInt(slider.value, 10) + 10);
            slider.value = size;
            updateFontSize(size);
            saveFontSize(size);
          });
        }

        /**
         * Update the font size CSS variable and display.
         */
        function updateFontSize(size) {
          document.documentElement.style.setProperty('--prayer-font-size', size + '%');
          if (valueDisplay) {
            valueDisplay.textContent = size + '%';
          }
        }

        /**
         * Save font size to localStorage.
         */
        function saveFontSize(size) {
          localStorage.setItem('divineMercyFontSize', size);
        }
      });
    }
  };

})(Drupal, drupalSettings, once);
