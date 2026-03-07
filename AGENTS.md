# Agents

Guidelines for AI agents working with this repository.

## Project overview

Docker container packaging project bundling
[Headscale](https://github.com/juanfont/headscale) (self-hosted Tailscale
control server) with
[Litestream](https://github.com/benbjohnson/litestream) (SQLite replication).
No application source code; only Dockerfile, shell scripts, YAML configs,
and CI workflows.

## Repository structure

```
Dockerfile                  # Multi-arch container build (amd64/arm64)
VERSION                     # Current version (plain text)
container/
  entrypoint.sh             # Container startup script (POSIX shell)
  headscale.yaml            # Headscale config template
  litestream.yml            # Litestream config template
docs/
  fly/                      # Fly.io deployment templates
play/
  compose.yaml              # Docker Compose for local development
.changes/                   # Changie changelog entries
.github/workflows/          # CI/CD pipelines
```

## Contribution policy

Only **bug fixes** accepted. Feature requests go to issues.
Every PR must include a changelog entry.

## Constraints

- Do not modify `VERSION` directly; managed by the release process
- Do not modify `.github/workflows/` unless explicitly requested
- Do not change upstream app behavior or add features; packaging-only repo
- Do not add secrets or credentials
- Do not modify `docs/fly/` or `play/compose.yaml` unless required for a
  documented bug fix

## Branch and commit conventions

- Branch from `main` using dashes (e.g. `fix-entrypoint-bug`), no slashes
- Commits: imperative mood, 50-char subject, body wrapped at 72 chars
  explaining what and why

## Making changes

### Key files

- `Dockerfile`: binary versions, SHA256 checksums, base image, env defaults
- `container/entrypoint.sh`: startup logic, config templating, database
  restore, process execution
- `container/headscale.yaml`: Headscale configuration template (variables
  substituted at startup via `entrypoint.sh`)
- `container/litestream.yml`: replication config template
- `play/compose.yaml`: local development stack with MinIO replicas

### Bumping upstream versions

The `Dockerfile` pins each binary by version and per-architecture SHA256
checksum. Always update **both** architectures together.

#### Headscale

1. Compute checksums (replace `VERSION` with target release, e.g. `0.27.1`):

   ```
   curl -sL https://github.com/juanfont/headscale/releases/download/vVERSION/headscale_VERSION_linux_amd64 | sha256sum -
   curl -sL https://github.com/juanfont/headscale/releases/download/vVERSION/headscale_VERSION_linux_arm64 | sha256sum -
   ```

2. Update `HEADSCALE_VERSION` and each `HEADSCALE_SHA256` in the corresponding
   `x86_64`/`aarch64` `case` branches.

#### Litestream

1. Compute checksums (replace `VERSION` with target release, e.g. `0.3.13`):

   ```
   curl -sL https://github.com/benbjohnson/litestream/releases/download/vVERSION/litestream-vVERSION-linux-amd64.tar.gz | sha256sum -
   curl -sL https://github.com/benbjohnson/litestream/releases/download/vVERSION/litestream-vVERSION-linux-arm64.tar.gz | sha256sum -
   ```

2. Update `LITESTREAM_VERSION` and each `LITESTREAM_SHA256` in the
   corresponding `x86_64`/`aarch64` `case` branches.

#### Validation

Run `docker compose build` from the `play/` directory to confirm correct
binary downloads, checksum verification, and smoke tests pass.

### Building locally

```
docker compose build
```

Run from the `play/` directory. Builds the image from the root `Dockerfile`
context. No tests beyond the Dockerfile's built-in smoke tests and SHA256
verification.

### Validation

All commands below run from the `play/` directory.

#### Build validation

Run `docker compose build` and confirm it completes without errors. This
verifies Dockerfile syntax, binary downloads, SHA256 checksums, and the
built-in smoke tests.

#### Runtime validation

When changes affect runtime behavior (entrypoint, config templates, version
bumps), verify the container starts and operates correctly:

1. Start the stack in detached mode:

   ```
   docker compose up -d
   ```

2. Wait for the health check interval (~30 s) and confirm all services
   report `(healthy)`:

   ```
   docker compose ps
   ```

3. Inspect server logs for startup errors or unexpected warnings:

   ```
   docker compose logs server
   ```

4. Verify the health endpoint returns HTTP 200:

   ```
   curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/health
   ```

5. Shut down the stack when done:

   ```
   docker compose down
   ```

#### Upgrade validation

When bumping Headscale or Litestream versions, test the database migration
path to catch incompatibilities early:

1. **Before** applying changes, build and start the current version to
   create a baseline database (`docker compose build && docker compose up -d`).
   Confirm the container is healthy, then stop it with
   `docker compose down`. The database volume persists across restarts.
2. Apply the version bump and rebuild (`docker compose build`).
3. Start the stack again (`docker compose up -d`). The new version will
   open the existing database and run any pending migrations.
4. Confirm the container reaches `(healthy)` status, check the logs for
   migration errors, and verify the health endpoint.
5. Shut down with `docker compose down`.

## Pull request conventions

PR titles should be short and descriptive. PR descriptions should focus on the
user-facing "why" using concise bullet points rather than restating
implementation details. Avoid repeating file names, checksums, or env var
names that are already visible in the diff.

Extract this information from the session context or ask the user if it cannot
be extrapolated from it.

## Changelog workflow

Uses [changie](https://changie.dev/). Every PR requires a changelog entry
unless labeled `skip changelog`.

### Creating a changelog entry

```
changie new -k fixed -b "Description of the change"
```

Valid `-k` values: `added`, `changed`, `fixed`, `security`, `internal`.
Run `changie new --help` for all options.

### CI checks

- **check-changelog**: fails PRs missing entries in
  `.changes/unreleased/*.yaml` or unmodified `CHANGELOG.md`
- **create-release-pr**: manually triggered; batches unreleased changie
  entries, updates `CHANGELOG.md` and `VERSION`, and opens a release PR.
  Trigger it with:

  ```
  gh workflow run create-release-pr.yml
  ```

- **release**: on `main` when `CHANGELOG.md` changes; builds multi-arch image
  and creates GitHub release
- **release-tip**: on `main` when `CHANGELOG.md` unchanged; builds `tip`
  pre-release image
