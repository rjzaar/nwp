<?php

namespace Drupal\Tests\sticky_comment\Unit\Util;

use Drupal\config_modify\Util\UpdateDefinitionCreator;
use Drupal\Core\Serialization\Yaml;
use Drupal\Tests\UnitTestCase;

/**
 * Tests for the Update Definition Creator.
 */
class UpdateDefinitionCreatorTest extends UnitTestCase {

  /**
   * The update definition creator under test.
   */
  protected UpdateDefinitionCreator $updateDefinitionCreator;

  /**
   * {@inheritdoc}
   */
  protected function setUp(): void {
    parent::setUp();
    $this->updateDefinitionCreator = new UpdateDefinitionCreator();
  }

  /**
   * Test that identical arrays are correctly detected.
   *
   * @dataProvider sameTrueProvider
   */
  public function testSameTrue(array $a, array $b) : void {
    $this->assertTrue($this->updateDefinitionCreator->isSame($a, $b, ['uuid', '_core']));
  }

  /**
   * Test that differing arrays are correctly detected.
   *
   * @dataProvider sameFalseProvider
   */
  public function testSameFalse(array $a, array $b) : void {
    $this->assertFalse($this->updateDefinitionCreator->isSame($a, $b, ['uuid', '_core']));
  }

  /**
   * Data provider for self:testSameTrue().
   */
  public function sameTrueProvider() : \Generator {
    $base = [
      'uuid' => 'bar',
      'a' => 'a',
      'b' => 0,
      'c' => [
        'd' => TRUE,
        'e' => FALSE,
        'empty' => [],
      ],
    ];

    yield 'identical array' => [$base, $base];

    // Add _core, omit uuid at top level. Should match, as both are removed
    // in normalization process.
    yield 'changed normalized values' => [
      $base,
      [
        '_core' => 'foo',
        'a' => 'a',
        'b' => 0,
        'c' => [
          'd' => TRUE,
          'e' => FALSE,
          'empty' => [],
        ],
      ],
    ];

    // Change order in top and deep level. Should match.
    yield 'different order should equal' => [
      $base,
      [
        'uuid' => 'bar',
        'b' => 0,
        'a' => 'a',
        'c' => [
          'e' => FALSE,
          'empty' => [],
          'd' => TRUE,
        ],
      ],
    ];
  }

  /**
   * Data provider for self:testSameFalse().
   */
  public function sameFalseProvider() : \Generator {
    $base = [
      'uuid' => 'bar',
      'a' => 'a',
      'b' => 0,
      'c' => [
        'd' => TRUE,
        'e' => FALSE,
        'empty' => [],
      ],
    ];

    // Add _core in deeper level. Should not match, as this is removed
    // only at the top level during normalization.
    yield "don't normalise nested _core" => [
      $base,
      [
        'uuid' => 'bar',
        'a' => 'a',
        'b' => 0,
        'c' => [
          '_core' => 'do-not-use-this-key',
          'd' => TRUE,
          'e' => FALSE,
          'empty' => [],
        ],
      ],
    ];

    // Add uuid in deeper level. Should not match, as this is removed
    // only at the top level during normalization.
    yield "don't normalize nested uuid" => [
      $base,
      [
        'uuid' => 'bar',
        'a' => 'a',
        'b' => 0,
        'c' => [
          'd' => TRUE,
          'e' => FALSE,
          'uuid' => 'important',
          'empty' => [],
        ],
      ],
    ];

    yield 'omit a component should not match' => [
      $base,
      [
        'uuid' => 'bar',
        'a' => 'a',
        'c' => [
          'd' => TRUE,
          'e' => FALSE,
          'empty' => [],
        ],
      ],
    ];

    // Add a component. Should not match.
    yield 'add a component should not match' => [
      $base,
      [
        'uuid' => 'bar',
        'a' => 'a',
        'b' => 0,
        'c' => [
          'd' => TRUE,
          'e' => FALSE,
          'empty' => [],
        ],
        'f' => 'f',
      ],
    ];

    yield '0 should not match a string' => [
      $base,
      [
        '_core' => 'foo',
        'uuid' => 'bar',
        'a' => 'a',
        'b' => 'b',
        'c' => [
          'd' => TRUE,
          'e' => FALSE,
          'empty' => [],
        ],
      ],
    ];

    yield '0 should not match NULL' => [
      $base,
      [
        '_core' => 'foo',
        'uuid' => 'bar',
        'a' => 'a',
        'b' => NULL,
        'c' => [
          'd' => TRUE,
          'e' => FALSE,
          'empty' => [],
        ],
      ],
    ];

    yield 'FALSE should not match a string' => [
      $base,
      [
        '_core' => 'foo',
        'uuid' => 'bar',
        'a' => 'a',
        'b' => 0,
        'c' => [
          'd' => TRUE,
          'e' => 'e',
          'empty' => [],
        ],
      ],
    ];

    yield 'TRUE should not match a string' => [
      $base,
      [
        '_core' => 'foo',
        'uuid' => 'bar',
        'a' => 'a',
        'b' => 0,
        'c' => [
          'd' => 'd',
          'e' => FALSE,
          'empty' => [],
        ],
      ],
    ];

    // Add an empty array at top, and remove at lower level.
    yield 'move empty array around' => [
      $base,
      [
        '_core' => 'foo',
        'uuid' => 'bar',
        'a' => 'a',
        'b' => 0,
        'c' => [
          'd' => TRUE,
          'e' => FALSE,
        ],
        'empty_two' => [],
      ],
    ];
  }

  /**
   * Test that produceDiff produces correct diffs.
   *
   * @dataProvider diffProvider
   */
  public function testProduceDiff(string $from, string $to, string $expected) : void {
    $from = Yaml::decode($from);
    $to = Yaml::decode($to);
    assert(is_array($from) && is_array($to));

    $outcome = Yaml::encode($this->updateDefinitionCreator->produceDiff($from, $to));

    $this->assertEquals($expected, $outcome);
  }

  /**
   * Data provider for the testProduceDiff test.
   */
  public function diffProvider() : \Generator {
    yield 'identical produces no changes' => [
      'from' => <<<YAML
        a: foo
        YAML,
      'to' => <<<YAML
        a: foo
        YAML,
      'expected' => '{  }',
    ];

    yield 'handles value change' => [
      'from' => <<<YAML
        a: foo
        YAML,
      'to' => <<<YAML
        a: bar
        YAML,
      'expected' => <<<YAML
        change:
          a: bar

        YAML,
    ];

    yield 'handles nested complex change' => [
      'from' => <<<YAML
        a:
         bar: foo
         baz: baz
        b: bar
        YAML,
      'to' => <<<YAML
        a:
          bar: bar
          foo: foo
        YAML,
      'expected' => <<<YAML
        add:
          a:
            foo: foo
        change:
          a:
            bar: bar
        delete:
          b: {  }
          a:
            baz: {  }

        YAML,
    ];

    yield 'ignores identical numerical arrays' => [
      'from' => <<<YAML
        dependencies:
          modules:
            - foo
            - bar
        YAML,
      'to' => <<<YAML
        dependencies:
          modules:
            - foo
            - bar
        YAML,
      'expected' => '{  }',
    ];

    yield 'handles numerical arrays 1' => [
      'from' => <<<YAML
        dependencies:
          modules:
            - foo
            - bar
        YAML,
      'to' => <<<YAML
        dependencies:
          modules:
            - bar
            - baz
        YAML,
      'expected' => <<<YAML
        add:
          dependencies:
            modules:
              - baz
        delete:
          dependencies:
            modules:
              - foo

        YAML,
    ];

    yield 'handles numerical arrays 2' => [
      'from' => <<<YAML
        dependencies:
          modules:
            - foo
            - bar
        YAML,
      'to' => <<<YAML
        dependencies:
          modules:
            - baz
            - foo
        YAML,
      'expected' => <<<YAML
        add:
          dependencies:
            modules:
              - baz
        delete:
          dependencies:
            modules:
              - bar

        YAML,
    ];

    yield 'update helper diff' => [
      'from' => <<<YAML
        uuid: 1234-5678-90
        id: test.config.id
        id_to_remove: test.remove_id
        type: old_type
        true_value: true
        null_value: null
        nested_array:
          flat_array:
            - value2
            - value1
            - value3
          custom_key: value
        YAML,
      'to' => <<<YAML
        uuid: 09-8765-4321
        id: test.config.id
        type: new_type
        true_value: FALSE
        null_value: FALSE
        nested_array:
          flat_array:
            - value2
            - value3
          custom_key: value
          custom_key_2: value2
        YAML,
      'expected' => <<<YAML
        add:
          nested_array:
            custom_key_2: value2
        change:
          uuid: 09-8765-4321
          type: new_type
          true_value: false
          null_value: false
        delete:
          id_to_remove: {  }
          nested_array:
            flat_array:
              - value1

        YAML,
    ];
  }

}
