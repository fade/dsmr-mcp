---
name: scaffold-project
description: Scaffold a new Common Lisp project from the dsmr-mcp skeleton when run in an empty directory. Generates a package-inferred ASDF system, packages, a Parachute smoke test, and delivery-discipline files via the dsmr-mcp MCP server.
---

# Scaffold a Common Lisp project

Use this skill to generate a fresh, delivery-disciplined Common Lisp
project skeleton in the current directory. It drives the dsmr-mcp MCP
server's `project-scaffold` verb, which emits a package-inferred ASDF
system, a mode-dispatching executable, a Parachute test suite, a build
recipe, a dev-boot script, dependency-preference docs, and a license with
per-file SPDX headers.

## Preconditions

- The current directory must be **empty or nearly empty**. The scaffold
  engine refuses to clobber an existing tree, so run this only when
  starting a new project.
- The dsmr-mcp MCP server must be connected (verbs `fs-set-project-root`
  and `project-scaffold` are available).

## Steps

1. Confirm the working directory is empty enough to scaffold into. If it
   already contains a project, stop and tell the user.

2. Anchor the dsmr-mcp write-jail to the current directory by calling the
   MCP verb **`fs-set-project-root`** with the absolute path of the
   current directory. The scaffold writes only under this root.

3. Call the MCP verb **`project-scaffold`** with the project options:
   - `name` (required): the project name in lisp-case, matching
     `^[a-z][a-z0-9-]*$` (for example `foo-lib`).
   - `license` (optional): an SPDX identifier; defaults to
     `AGPL-3.0-or-later`.
   - `author`, `copyright`, `description`, `year` (optional): metadata for
     the `.asd` file and the license header.
   - `destination` (optional): a relative parent directory under the root
     where `<name>/` is created; defaults to `scaffolds`. Pass `"."` to
     scaffold directly into the current directory.

4. Report the manifest the verb returns: the created files, the project
   path, and the next-step commands (how to load and test the new
   system).

## Notes

- Ask the user for the project name and license up front if they were not
  supplied.
- If `project-scaffold` reports that the target directory is not empty,
  surface that to the user rather than forcing an overwrite.
