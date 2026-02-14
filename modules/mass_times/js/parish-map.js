(function (Drupal) {
  'use strict';

  Drupal.behaviors.massTimesParishMap = {
    attach: function (context) {
      var container = context.querySelector('#mass-times-map');
      if (!container || container.dataset.initialized) {
        return;
      }
      container.dataset.initialized = 'true';

      var wrapper = container.closest('.mass-times-parish-map');
      var centreLat = parseFloat(wrapper.dataset.centreLat) || -37.8131;
      var centreLng = parseFloat(wrapper.dataset.centreLng) || 145.2285;

      var map = L.map('mass-times-map').setView([centreLat, centreLng], 12);

      L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
        maxZoom: 18
      }).addTo(map);

      // Centre marker.
      L.circleMarker([centreLat, centreLng], {
        radius: 6,
        color: '#333',
        fillColor: '#666',
        fillOpacity: 0.8
      }).addTo(map).bindPopup('Centre point');

      // Parish markers from the list items.
      var items = wrapper.querySelectorAll('.parish-item');
      var bounds = [[centreLat, centreLng]];

      items.forEach(function (item) {
        var lat = parseFloat(item.dataset.lat);
        var lng = parseFloat(item.dataset.lng);
        if (!lat || !lng) {
          return;
        }

        var link = item.querySelector('a');
        var name = link ? link.textContent : 'Parish';
        var href = link ? link.getAttribute('href') : '#';
        var distance = item.querySelector('.parish-distance');
        var distText = distance ? ' ' + distance.textContent : '';

        var marker = L.marker([lat, lng]).addTo(map);
        marker.bindPopup('<strong><a href="' + href + '">' + name + '</a></strong>' + distText);
        bounds.push([lat, lng]);
      });

      if (bounds.length > 1) {
        map.fitBounds(bounds, { padding: [30, 30] });
      }
    }
  };

})(Drupal);
