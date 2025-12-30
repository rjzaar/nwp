@smoke @p0
Feature: Smoke Tests
  Critical path validation to ensure site is operational

  @api
  Scenario: Homepage loads successfully
    Given I am on the homepage
    Then the response status code should be 200
    And I should see the site title

  @api
  Scenario: User login page is accessible
    Given I am on "/user/login"
    Then the response status code should be 200
    And I should see "Log in"
    And I should see a "Username" field
    And I should see a "Password" field

  @api
  Scenario: Anonymous user cannot access admin
    Given I am on "/admin"
    Then I should see "Access denied"

  @api
  Scenario: Basic content pages load
    Given I am on "/node"
    Then the response status code should not be 500

  @api @smoke
  Scenario: Search page is accessible
    Given I am on "/search"
    Then the response status code should be 200

  @javascript @smoke
  Scenario: Homepage renders correctly with JavaScript
    Given I am on the homepage
    Then I should see the site title
    And I should not see any JavaScript errors

  @api @destructive @p1
  Scenario: Administrator can log in
    Given I am logged in as a user with the "administrator" role
    Then I should see "Log out"
    And I should see the administration menu
