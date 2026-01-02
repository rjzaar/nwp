/**
 * @file
 * Reflection selector functionality for the Divine Mercy Chaplet.
 */

(function (Drupal, drupalSettings, once) {
  'use strict';

  Drupal.behaviors.divineMercyReflectionSelector = {
    attach: function (context, settings) {
      const wrapper = once('reflection-selector', '#reflection-selector-wrapper', context);
      if (!wrapper.length) {
        return;
      }

      const reflectionSets = settings.divineMercy?.reflectionSets || [];
      let currentSetId = null;
      let currentDecade = 1;

      // Elements
      const buttons = document.querySelectorAll('.reflection-btn');
      const display = document.getElementById('reflection-display');
      const title = document.getElementById('reflection-title');
      const indicator = document.getElementById('decade-indicator');
      const list = document.getElementById('reflection-list');
      const prevBtn = document.getElementById('decade-prev');
      const nextBtn = document.getElementById('decade-next');

      // Bottom navigation elements
      const indicatorBottom = document.querySelector('.decade-indicator-bottom');
      const prevBtnBottom = document.querySelector('.decade-prev-bottom');
      const nextBtnBottom = document.querySelector('.decade-next-bottom');

      // Get set data by ID
      function getSetById(id) {
        return reflectionSets.find(set => set.id == id);
      }

      // Format reflection text with expandable "..." sections
      function formatReflectionText(text, index) {
        // Check if text contains "..."
        const ellipsisIndex = text.indexOf('...');
        if (ellipsisIndex === -1) {
          return text;
        }

        const beforeEllipsis = text.substring(0, ellipsisIndex);
        const afterEllipsis = text.substring(ellipsisIndex + 3).trim();

        if (!afterEllipsis) {
          return text;
        }

        const uniqueId = `reflection-expand-${currentDecade}-${index}`;
        return `${beforeEllipsis}<button type="button" class="reflection-ellipsis" data-target="${uniqueId}" aria-expanded="false" aria-label="Show more">...</button><span class="reflection-hidden-text" id="${uniqueId}" style="display: none;"> ${afterEllipsis}</span>`;
      }

      // Render current decade reflections
      function renderDecade() {
        const set = getSetById(currentSetId);
        if (!set || !set.decades[currentDecade]) {
          list.innerHTML = '<li>No reflections available for this decade.</li>';
          return;
        }

        const reflections = set.decades[currentDecade];
        list.innerHTML = reflections
          .map((text, index) => `<li><span class="reflection-number">${index + 1}.</span> ${formatReflectionText(text, index)}</li>`)
          .join('');

        // Add click handlers for ellipsis buttons
        list.querySelectorAll('.reflection-ellipsis').forEach(btn => {
          btn.addEventListener('click', function() {
            const targetId = this.dataset.target;
            const hiddenText = document.getElementById(targetId);
            if (hiddenText) {
              const isHidden = hiddenText.style.display === 'none';
              hiddenText.style.display = isHidden ? 'inline' : 'none';
              this.setAttribute('aria-expanded', isHidden ? 'true' : 'false');
              this.classList.toggle('expanded', isHidden);
            }
          });
        });

        // Update indicator
        indicator.textContent = `Decade ${currentDecade} of 5`;
        if (indicatorBottom) {
          indicatorBottom.textContent = `Decade ${currentDecade} of 5`;
        }

        // Update button states
        prevBtn.disabled = currentDecade <= 1;
        nextBtn.disabled = currentDecade >= 5;
        if (prevBtnBottom) {
          prevBtnBottom.disabled = currentDecade <= 1;
        }
        if (nextBtnBottom) {
          nextBtnBottom.disabled = currentDecade >= 5;
        }
      }

      // Handle set selection
      function selectSet(setId) {
        // Update button states
        buttons.forEach(btn => {
          const isActive = btn.dataset.setId === setId;
          btn.setAttribute('aria-pressed', isActive ? 'true' : 'false');
          btn.classList.toggle('active', isActive);
        });

        // Get elements for showing/hiding
        const header = document.querySelector('.reflection-header');
        const reflectionList = document.getElementById('reflection-list');

        if (setId === 'none') {
          currentSetId = null;
          // Show display but hide the header (title and navigation) and reflection list
          display.style.display = 'block';
          if (header) header.style.display = 'none';
          if (reflectionList) reflectionList.style.display = 'none';
          return;
        }

        const set = getSetById(setId);
        if (!set) {
          return;
        }

        currentSetId = setId;
        currentDecade = 1;
        title.textContent = set.title;
        display.style.display = 'block';
        // Show header and list for regular reflection sets
        if (header) header.style.display = 'flex';
        if (reflectionList) reflectionList.style.display = 'block';
        renderDecade();
      }

      // Button click handlers
      buttons.forEach(btn => {
        btn.addEventListener('click', function () {
          selectSet(this.dataset.setId);
        });
      });

      // Navigation handlers
      if (prevBtn) {
        prevBtn.addEventListener('click', function () {
          if (currentDecade > 1) {
            currentDecade--;
            renderDecade();
          }
        });
      }

      if (nextBtn) {
        nextBtn.addEventListener('click', function () {
          if (currentDecade < 5) {
            currentDecade++;
            renderDecade();
          }
        });
      }

      // Bottom navigation handlers
      if (prevBtnBottom) {
        prevBtnBottom.addEventListener('click', function () {
          if (currentDecade > 1) {
            currentDecade--;
            renderDecade();
            // Scroll to top of reflection display
            display.scrollIntoView({ behavior: 'smooth', block: 'start' });
          }
        });
      }

      if (nextBtnBottom) {
        nextBtnBottom.addEventListener('click', function () {
          if (currentDecade < 5) {
            currentDecade++;
            renderDecade();
            // Scroll to top of reflection display
            display.scrollIntoView({ behavior: 'smooth', block: 'start' });
          }
        });
      }

      // Keyboard navigation
      document.addEventListener('keydown', function (e) {
        if (!currentSetId) return;

        if (e.key === 'ArrowLeft' && currentDecade > 1) {
          currentDecade--;
          renderDecade();
        } else if (e.key === 'ArrowRight' && currentDecade < 5) {
          currentDecade++;
          renderDecade();
        }
      });

      // Auto-select "None" on page load to show the basic prayers
      selectSet('none');
    }
  };

})(Drupal, drupalSettings, once);
