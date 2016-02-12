# Restore deleted Drupal nodes
A simple script to restore deleted Drupal nodes on Acquia Cloud by importing them from another environment

# Usage: restore [options]

-s, --sitename SITE              Name of Acquia Cloud site

-r, --source-env ENV             Source environment to import from

-t, --target-env ENV             Target environment to import to

-l, --limit COUNT                Export/import only COUNT nodes. This may be helpful for testing when the node list is long

-n, --source-nids NIDS           List of source node nids separated by commas

-c, --content-types TYPES        Content types to work on

-g, --languages LANGS            Node languages - separated by commas, to work on

-v, --verbose                    Turn on verbose mode
