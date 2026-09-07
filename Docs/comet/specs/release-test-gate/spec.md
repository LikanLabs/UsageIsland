# Tagged release test gate

## Purpose

A GitHub tagged release built from this repository cannot package or publish
until the tagged commit passes the same test and resilience commands CI uses.

## Behavior

`.github/workflows/release.yml` remains triggered by tags matching `v*.*.*`.

The `release` job, on the tagged commit, runs in this order:

1. checkout
2. `swift test`
3. `./Scripts/verify-resilience.sh`
4. existing universal package build (`Scripts/package-app.sh`)
5. zip and checksum
6. `gh release create`

If `swift test` or `./Scripts/verify-resilience.sh` fails, later package and
publish steps do not run.

Commands stay in this job. The workflow does not query another workflow's
check status to decide whether to publish.

## Non-behavior

This capability does not publish a known-broken release to prove the gate.

It does not require a reusable workflow until duplicated commands become a
real maintenance problem.

## Acceptance

- Release YAML lists test and resilience steps before package and publish.
- A verification method that does not create a GitHub release shows that a
  failing test step prevents the publish step from running.
