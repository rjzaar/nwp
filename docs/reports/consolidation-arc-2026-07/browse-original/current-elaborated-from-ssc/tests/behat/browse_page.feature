@local @local_browse
Feature: Tabbed course front-door
  In order to find the right course without an account
  As any (anonymous) visitor
  I need a tabbed page: Curated intent tiles, the Ascent rails, and a Browse list

  Background:
    Given the following "categories" exist:
      | name             | category | idnumber        |
      | Sacraments rail  | 0        | rail_sacraments |
      | Prayer rail      | 0        | rail_prayer     |
    And the following "courses" exist:
      | category        | shortname | fullname                      |
      | rail_sacraments | A5        | The Sacraments and Grace      |
      | rail_sacraments | A6        | Confession as Encounter       |
      | rail_prayer     | B1        | Why Prayer Is Essential       |
      | rail_prayer     | B4        | Distractions in Prayer        |
      | rail_prayer     | B5        | The Daily Examen              |

  Scenario: Curated tab is the default and shows intent tiles
    Given I am on the "/local/browse/" page
    Then I should see "Where would you like to begin?"
    And I should see "Where to begin"
    And I should see "The journey"
    And I should see "Browse everything"
    # A seed tile whose courses resolve in this Moodle renders.
    And I should see "The Sacraments and Grace"

  Scenario: Ascent tab groups courses by rail
    Given I am on the "/local/browse/?view=ascent" page
    Then I should see "Sacraments rail"
    And I should see "Prayer rail"
    And I should see "A5"
    And I should see "Confession as Encounter"
    And I should see "B1"

  Scenario: Browse tab shows the flat list and the N8 toggles
    Given I am on the "/local/browse/?view=browse" page
    Then I should see "Catalog version"
    And I should see "v3 (current)"
    And I should see "v1 archive"
    And I should see "Courses + book studies"
    And I should see "The Sacraments and Grace"
    And I should see "Why Prayer Is Essential"

  Scenario: Browse v1 toggle shows read-only archive entries
    Given I am on the "/local/browse/?view=browse&cat=v1" page
    Then I should see "frozen and read-only"
    # v1 archive titles (differ from v3), e.g. v1 D6:
    And I should see "Discernment in Daily Life"

  Scenario: Book-studies toggle shows the copyright-gated notice
    Given I am on the "/local/browse/?view=browse&content=books" page
    Then I should see "Book studies"

  Scenario: Course cards link to /course/view.php?id=X
    Given I am on the "/local/browse/?view=ascent" page
    When I follow "The Sacraments and Grace"
    Then I should be on the course view page for "A5"
