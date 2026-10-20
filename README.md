# Cobble

Package catalog for [CubeOS](https://github.com/denmoth/CubeOS). The CubeOS package manager, `stew`, reads
`index.json5` from here and downloads packages from this repository's releases.

## Installing CubeOS

On a clean CC: Tweaked computer with HTTP enabled:

```
wget run https://raw.githubusercontent.com/denmoth/cobble/main/install.lua
```

If the computer runs out of space, put a second computer next to it, connect them with modems and run this on the second
one:

```
wget run https://raw.githubusercontent.com/denmoth/cobble/main/pkghost.lua
```

It shows a code. Pick "Second computer" in the installer (or run `stew host pair CODE` later) and type it in.

## What's here

`index.json5` is the catalog itself. `install.lua` and `pkghost.lua` are the two programs above. `owners.json5` says who
owns which package id. Each package that is published from source has a folder in `packages/` with a `recipe.json5`
pointing at its sources; `packages/denmoth.hello` is just an example.

The system packages (`cubeos.*`) are in the `system-<version>` release.

## Publishing a package

Add `packages/<author>.<name>/recipe.json5` and open a pull request. If the sources live here, the recipe is
`{ id: "author.name", owner: "your-github-login", source: { kind: "here" } }` and the files go in `src/`. If they live
in your own repository, use `source: { kind: "git", repo: "https://github.com/x/y", ref: "<tag or commit>" }` instead.
The sources need a `package.json5` manifest; the format is in `docs/packages/02-manifest.md` in the CubeOS repository.

A few rules: the id has the form `author.name` and can't be taken by someone else, a package is at most 256 KB, and
`cubeos.*` ids are reserved for CubeOS itself. Bump the version for every change, since a published version can't be
replaced. New packages are reviewed by hand. Updates to your own package go through on their own unless they ask for new
permissions.
