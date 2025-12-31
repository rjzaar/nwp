@authentication @p1
Feature: User Authentication
  Verify user authentication and authorization functionality

  @api
  Scenario: Login page displays correctly
    Given I am on "/user/login"
    Then the response status code should be 200
    And I should see "Log in"
    And I should see a "Username" field
    And I should see a "Password" field

  @api
  Scenario: User can log in with valid credentials
    Given users:
      | name     | mail            | pass     | status |
      | testuser | test@test.local | testpass | 1      |
    And I am on "/user/login"
    When I fill in "Username" with "testuser"
    And I fill in "Password" with "testpass"
    And I press "Log in"
    Then I should see "Log out"

  @api
  Scenario: User cannot log in with invalid credentials
    Given I am on "/user/login"
    When I fill in "Username" with "invaliduser"
    And I fill in "Password" with "wrongpassword"
    And I press "Log in"
    Then I should see "Unrecognized username or password"

  @api
  Scenario: User can log out
    Given I am logged in as a user with the "authenticated" role
    When I click "Log out"
    Then I should see "Log in"
    And I should not see "Log out"

  @api
  Scenario: Password reset page is accessible
    Given I am on "/user/password"
    Then the response status code should be 200
    And I should see "Reset your password"

  @api
  Scenario: User registration page is accessible
    Given I am on "/user/register"
    Then the response status code should not be 403
    And I should see "Create new account"

  @api @security
  Scenario: Brute force protection is active
    Given I am on "/user/login"
    When I fill in "Username" with "admin"
    And I fill in "Password" with "wrongpassword1"
    And I press "Log in"
    And I fill in "Password" with "wrongpassword2"
    And I press "Log in"
    And I fill in "Password" with "wrongpassword3"
    And I press "Log in"
    Then I should see "Too many failed login attempts"

  @api @destructive
  Scenario: Administrator has admin access
    Given I am logged in as a user with the "administrator" role
    When I go to "/admin"
    Then the response status code should be 200
    And I should see the administration menu

  @api
  Scenario: Authenticated user cannot access admin without permission
    Given I am logged in as a user with the "authenticated" role
    When I go to "/admin"
    Then I should see "Access denied"
