@p1
Feature: Content Management
  Basic content creation and management tests

  Background:
    Given I am logged in as a user with the "administrator" role

  @api @destructive
  Scenario: Create a basic page
    Given I am on "/node/add/page"
    When I fill in "Title" with "Test Page"
    And I fill in "Body" with "This is test content."
    And I press "Save"
    Then I should see "Test Page has been created"
    And I should see "This is test content."

  @api @destructive
  Scenario: Edit existing content
    Given I have created test content of type "page" with title "Edit Test Page"
    When I visit the edit page for this content
    And I fill in "Title" with "Updated Page Title"
    And I press "Save"
    Then I should see "Updated Page Title has been updated"

  @api
  Scenario: View published content as anonymous
    Given I have created test content of type "page" with title "Public Page"
    When I am not logged in
    And I visit this content
    Then I should see "Public Page"
    And the response status code should be 200

  @javascript @p2
  Scenario: Content preview works
    Given I am on "/node/add/page"
    When I fill in "Title" with "Preview Test"
    And I fill in "Body" with "Preview content here."
    And I press "Preview"
    Then I should see "Preview Test"
    And I should see "Preview content here."

  @api @destructive @p3
  Scenario: Delete content
    Given I have created test content of type "page" with title "Delete Test Page"
    When I visit the edit page for this content
    And I click "Delete"
    And I press "Delete"
    Then I should see "has been deleted"
