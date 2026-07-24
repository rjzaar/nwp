@local @local_browse
Feature: All-courses browse page
  In order to find a course without clicking through category trees
  As any visitor
  I need a single page that lists every course grouped by Paradigm rail

  Background:
    Given the following "categories" exist:
      | name             | category | idnumber |
      | Sacraments rail  | 0        | sacr     |
      | Prayer rail      | 0        | pray     |
    And the following "courses" exist:
      | category | shortname | fullname                      |
      | sacr     | A5        | The Sacraments                |
      | sacr     | A6        | Confession as Encounter       |
      | pray     | B1        | Why Prayer Is Essential       |

  Scenario: Anonymous visitor sees all courses grouped by rail
    Given I am on the "/local/browse/" page
    Then I should see "All courses"
    And I should see "Sacraments rail"
    And I should see "Prayer rail"
    And I should see "A5"
    And I should see "The Sacraments"
    And I should see "A6"
    And I should see "Confession as Encounter"
    And I should see "B1"
    And I should see "Why Prayer Is Essential"

  Scenario: Course cards link to /course/view.php?id=X
    Given I am on the "/local/browse/" page
    When I follow "The Sacraments"
    Then I should be on the course view page for "A5"

  Scenario: Empty categories are not displayed
    Given the following "categories" exist:
      | name      | category | idnumber |
      | Empty rail | 0       | empty    |
    And I am on the "/local/browse/" page
    Then I should not see "Empty rail"
