/**
 * @file
 * Expandable sections behavior for Divine Mercy module.
 */

(function (Drupal, once) {
  'use strict';

  /**
   * Expandable sections behavior.
   */
  Drupal.behaviors.divineMercyExpandable = {
    attach: function (context) {
      // Handle expand buttons.
      once('divine-mercy-expandable', '[data-target]', context).forEach(function (trigger) {
        trigger.addEventListener('click', function (e) {
          e.preventDefault();

          var targetId = this.getAttribute('data-target');
          var target = document.getElementById(targetId);

          if (target) {
            var isExpanded = target.style.display !== 'none';

            if (isExpanded) {
              target.style.display = 'none';
              this.setAttribute('aria-expanded', 'false');
              this.classList.remove('is-expanded');
            } else {
              target.style.display = 'block';
              this.setAttribute('aria-expanded', 'true');
              this.classList.add('is-expanded');
            }
          }
        });
      });

      // Handle generic expandable elements (blue ellipsis pattern).
      once('divine-mercy-ellipsis', '.prayer-expandable-trigger', context).forEach(function (trigger) {
        trigger.addEventListener('click', function (e) {
          e.preventDefault();

          var expandable = this.nextElementSibling;
          if (expandable && expandable.classList.contains('prayer-expandable')) {
            expandable.classList.toggle('expanded');
            this.setAttribute('aria-expanded', expandable.classList.contains('expanded'));
          }
        });
      });
    }
  };

})(Drupal, once);
