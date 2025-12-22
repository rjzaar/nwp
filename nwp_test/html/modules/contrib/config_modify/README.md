# Config Modify

This module allows other modules to define changes to installable configuration
in a `config/modify` folder.

## Usage
This module will try to apply modifications whenever Drupal core would apply
config from `config/optional`.

### Modification Format
Modifications are defined in YAML files in the `config/modify` folder of your
module. Files must be named `<module>.<unique>.yml` where `<module>` matches the
name of your module and `<unique>` is a unique string (e.g. `add_search_field`).

The files contain two top-level keys: `dependencies` and `items`. The contents
of `dependencies` matches Drupal core's config dependency format. `items` should
contain a list of named config items using the Config Update Definition format
from the [`update_helper` module](https://www.drupal.org/project/update_helper).

All configuration keys under `items` are implicit config dependencies, providing
for atomic updates.

For example to add an article field to a search index:

```yaml
dependencies:
  config:
    - field.field.node.article.body
items:
  search_api.index.my_search:
    expected_config: { }
    add:
      field_settings:
        article_body:
          label: Article Contents
          datasource_id: 'entity:node'
          property_path: body
          type: text
          dependencies:
            config: field.field.node.article.body
```

The above file will automatically add an `article_body` field to the `my_search`
index when the search index exists and the `body` field exists on the `article`
node type. If the search index or the field does not exist it will do nothing.
