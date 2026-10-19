# Cobble

The official package catalog of CubeOS, an operating system for ComputerCraft (CC:Tweaked) computers. The package manager
`stew` reads `index.json5` from here and downloads ready `.cpk` packages from the GitHub releases of this repository.

## Install CubeOS

On a clean ComputerCraft computer with HTTP enabled:

```
wget run https://raw.githubusercontent.com/denmoth/cobble/main/install.lua
```

The installer asks for the language, the profile (minimal text system, desktop, everything or your own choice), how to keep
the packages, your settings and your account. A computer with pixel graphics (CC: Graphics) gets the graphical installer and
the CDE desktop.

Not enough space? Put a second computer next to it, connect both with modems and run on the second one:

```
wget run https://raw.githubusercontent.com/denmoth/cobble/main/pkghost.lua
```

Then pick "Second computer" in the installer (or `stew host pair CODE` later) and type the code it shows.

## Layout

```
index.json5        the catalog: packages, versions, links to .cpk files, hashes, sizes, permissions
install.lua        the installer (one file, runs on plain CraftOS)
pkghost.lua        package storage on a second computer
owners.json5       who owns which package id; "cubeos" lists the owners of the project
packages/<id>/     recipe.json5 (where the sources are, who owns the package) and src/ when the sources live here
```

System packages (`cubeos.*`) are in the release `system-<version>`; other packages in releases named `<id>-<version>`.
`packages/denmoth.hello` is only an example.

## Adding a package

1. Create `packages/<author>.<name>/recipe.json5`:
   - sources here: `{ id: "author.name", owner: "your-github-login", source: { kind: "here" } }` with the files in `src/`;
   - sources in your repository: `source: { kind: "git", repo: "https://github.com/x/y", ref: "<tag or commit>", path: "subfolder" }`.
2. The sources need a `package.json5` manifest (see `docs/packages/02-manifest.md` in the CubeOS repository).
3. Open a pull request. Packages are built from their sources; prebuilt archives are not accepted.

From inside the game, `stew publish <folder>` will open such a pull request for you once the publishing service is online.

## Acceptance rules

- The manifest is complete; the id has the form `author.name`, is unique and not taken by someone else.
- A package is at most 256 KB (larger by agreement).
- `cubeos.*` ids are reserved for the owners of the project.
- A new package is reviewed by a person. An update of your own package without new permissions is accepted automatically
  when the checks pass; new permissions are reviewed by a person.
- Raise the version for every change: a published version cannot be replaced.
