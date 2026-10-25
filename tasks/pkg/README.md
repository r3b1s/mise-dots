# tasks/pkg/
This directory is for simple tasks that install a package globally via mise.

For example:

```sh
mise use -g npm:getpaseo/cli
```


## Why?
Mostly for tracking the mise-installable tools we like, but don't want to include as installed by default in the global mise config.

Implementing them as tasks also means we don't have to keep mental tally of the mise-specific package names/syntax.
