/**
 * @file
 * Eucharist adoration video behavior for Divine Mercy module.
 */

(function (Drupal, once) {
  'use strict';

  /**
   * Eucharist adoration behavior.
   */
  Drupal.behaviors.divineMercyAdoration = {
    attach: function (context) {
      once('divine-mercy-adoration', '#eucharist-adoration', context).forEach(function (adorationElement) {
        var toggleBtn = adorationElement.querySelector('.adoration-toggle');
        var content = adorationElement.querySelector('.adoration-content');
        var channelSelect = adorationElement.querySelector('#adoration-channel');
        var iframe = adorationElement.querySelector('#adoration-iframe');

        // Toggle visibility.
        if (toggleBtn && content) {
          var chapletElement = document.querySelector('.divine-mercy-chaplet');

          // Check saved preference.
          var isHidden = localStorage.getItem('adorationHidden') === 'true';
          if (isHidden) {
            content.style.display = 'none';
            toggleBtn.setAttribute('aria-expanded', 'false');
            toggleBtn.querySelector('.toggle-icon').textContent = '+';
            adorationElement.classList.add('is-collapsed');
            if (chapletElement) {
              chapletElement.classList.add('adoration-collapsed');
            }
          }

          toggleBtn.addEventListener('click', function () {
            var isCurrentlyHidden = content.style.display === 'none';

            if (isCurrentlyHidden) {
              content.style.display = 'block';
              this.setAttribute('aria-expanded', 'true');
              this.querySelector('.toggle-icon').textContent = '×';
              localStorage.setItem('adorationHidden', 'false');
              adorationElement.classList.remove('is-collapsed');
              if (chapletElement) {
                chapletElement.classList.remove('adoration-collapsed');
              }
            } else {
              content.style.display = 'none';
              this.setAttribute('aria-expanded', 'false');
              this.querySelector('.toggle-icon').textContent = '+';
              localStorage.setItem('adorationHidden', 'true');
              adorationElement.classList.add('is-collapsed');
              if (chapletElement) {
                chapletElement.classList.add('adoration-collapsed');
              }
            }
          });
        }

        // Channel selector.
        if (channelSelect && iframe) {
          channelSelect.addEventListener('change', function () {
            var newUrl = this.value;
            iframe.src = newUrl;

            // Save preference.
            localStorage.setItem('adorationChannel', newUrl);
          });

          // Restore saved channel.
          var savedChannel = localStorage.getItem('adorationChannel');
          if (savedChannel) {
            channelSelect.value = savedChannel;
            iframe.src = savedChannel;
          }
        }
      });
    }
  };

})(Drupal, once);
