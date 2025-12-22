/**
 * @file
 * JavaScript behaviors for the Workflow Assignment module.
 */

(function ($, Drupal) {
  'use strict';

  /**
   * Behavior for expandable table cells.
   */
  Drupal.behaviors.workflowExpandableCells = {
    attach: function (context, settings) {
      // Handle expandable cells
      $('.expandable-cell', context).once('expandable-cell').each(function () {
        var $cell = $(this);
        var fullText = $cell.data('full-text');
        var $content = $cell.find('.cell-content');
        var isExpanded = false;
        var isEditing = false;
        
        // Click to expand/collapse
        $cell.on('click', function (e) {
          if (isEditing) {
            return;
          }
          
          if (!isExpanded) {
            $content.text(fullText);
            $cell.addClass('expanded');
            isExpanded = true;
          } else {
            var truncated = truncateText(fullText, 50);
            $content.text(truncated);
            $cell.removeClass('expanded');
            isExpanded = false;
          }
        });
        
        // Double-click to edit (only for description and comments)
        if ($cell.closest('.description-cell, .comments-cell').length) {
          $cell.on('dblclick', function (e) {
            e.stopPropagation();
            
            if (isEditing) {
              return;
            }
            
            isEditing = true;
            var originalText = fullText === '-' ? '' : fullText;
            
            // Create textarea
            var $textarea = $('<textarea>').val(originalText);
            var $saveBtn = $('<button class="save-btn">Save</button>');
            var $cancelBtn = $('<button class="cancel-btn">Cancel</button>');
            var $actions = $('<div class="edit-actions">').append($saveBtn, $cancelBtn);
            
            $cell.addClass('editing');
            $cell.empty().append($textarea, $actions);
            $textarea.focus().select();
            
            // Save handler
            $saveBtn.on('click', function () {
              var newText = $textarea.val() || '-';
              fullText = newText;
              $cell.data('full-text', fullText);
              
              // Here you would normally make an AJAX call to save the data
              // For now, we'll just update the display
              
              $cell.removeClass('editing expanded');
              $cell.empty().append($('<span class="cell-content">').text(truncateText(fullText, 50)));
              isEditing = false;
              isExpanded = false;
              
              // Show success message
              showMessage('Changes saved temporarily. Save the form to persist changes.');
            });
            
            // Cancel handler
            $cancelBtn.on('click', function () {
              $cell.removeClass('editing');
              $cell.empty().append($('<span class="cell-content">').text(isExpanded ? fullText : truncateText(fullText, 50)));
              isEditing = false;
            });
            
            // Handle escape key
            $textarea.on('keydown', function (e) {
              if (e.key === 'Escape') {
                $cancelBtn.click();
              }
            });
          });
        }
      });
    }
  };
  
  /**
   * Helper function to truncate text.
   */
  function truncateText(text, maxLength) {
    if (text.length <= maxLength) {
      return text;
    }
    return text.substring(0, maxLength) + '...';
  }
  
  /**
   * Helper function to show messages.
   */
  function showMessage(message) {
    var $message = $('<div class="messages messages--status">').text(message);
    $('#workflow-assignments-table').before($message);
    setTimeout(function () {
      $message.fadeOut(function () {
        $(this).remove();
      });
    }, 3000);
  }

})(jQuery, Drupal);
