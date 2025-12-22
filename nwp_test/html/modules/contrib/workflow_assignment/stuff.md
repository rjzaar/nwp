# Coding standards
composer global require drupal/coder
phpcs --standard=Drupal,DrupalPractice --extensions=php,module,inc,install src/

# Fix coding standards
phpcbf --standard=Drupal,DrupalPractice --extensions=php,module,inc,install src/

# Static analysis
composer require --dev phpstan/phpstan mglaman/phpstan-drupal
vendor/bin/phpstan analyse src/ --level=1
