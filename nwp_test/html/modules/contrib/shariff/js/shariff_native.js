(function (Drupal, once) {
  Drupal.behaviors.shariffNative = {
    attach: function attach(context, settings) {
      if (navigator.share) {
        var blocksToHide = once('shariff_native', context.querySelectorAll('.shariff[data-hidden="1"]'));
        Array.prototype.forEach.call(blocksToHide, function (blockToHide) {
          // If there is a standard block wrapper.
          var wrapper = blockToHide.closest('.block-shariff');
          if (wrapper) {
            if (!wrapper.classList.contains('visually-hidden')) wrapper.classList.add('visually-hidden');
            return;
          }
          // If there is none (e.g. custom block template used).
          if (!blockToHide.classList.contains('visually-hidden')) blockToHide.classList.add('visually-hidden');
        });
      }
    }
  };
})(Drupal, once);
