# Repository Guidelines

## Project Structure & Module Organization

This repository currently contains `AWS-Instance-Plan.md`, the implementation specification for a Bash-based EC2 control toolkit. Read it before making changes. Source code, tests, and build tooling have not been added yet.

Place the planned CLI in `bin/ec2ctl`, fake-AWS tests in `tests/`, and installation helpers in `scripts/`. Keep the region and instance ID in a committed, non-secret configuration file. Store maintenance logs outside Git tracking. No frontend or asset pipeline is planned.

## Build, Test, and Development Commands

There is currently no build step or runnable test suite. Once implemented, use:

- `./bin/ec2ctl --profile NAME status`: inspect EC2 state and Systems Manager availability.
- `./bin/ec2ctl --profile NAME start`: start the instance and wait for health checks.
- `./bin/ec2ctl --profile NAME stop`: request shutdown and wait until stopped.
- `./bin/ec2ctl --profile NAME cost-audit`: inspect resources that incur costs while stopped.
- `bash -n bin/ec2ctl` and `shellcheck bin/ec2ctl`: check shell syntax and lint the CLI.

The planned `maintain` command installs Ubuntu updates and always stops the instance afterward, including on failure. Run it only during an approved maintenance window.

## Coding Style & Naming Conventions

Use Bash with two-space indentation, quoted variable expansions, and descriptive `snake_case` function names. Keep CLI subcommands consistent with the plan, including `cost-audit`. Use ShellCheck for shell linting; no formatter is configured. Give AWS waits finite timeouts and preserve meaningful failure exit codes.

## Testing Guidelines

Use a fake `aws` executable on `PATH` for automated tests. No testing framework or numerical coverage threshold is established. Name shell tests `tests/test_<behavior>.sh` and document their execution command when introduced.

Cover EC2 transitions, timeouts, unavailable Systems Manager, patch success/failure, cleanup shutdown, and concurrent-maintenance locking. Keep live AWS integration checks separate and explicitly authorized.

## Commit & Pull Request Guidelines

No usable Git history exists yet. Use concise, imperative commit subjects, such as `Add EC2 status command`. PRs should describe behavior changes, validation performed, related issues, and operational effects on scheduling, IAM, or shutdown.

## Security & Configuration

Never commit credentials, private keys, command output, or maintenance logs. Keep AWS credentials in local profiles under `~/.aws`. Restrict IAM access to the selected instance. Weekly scheduling belongs to the local cron host in America/Chicago; do not introduce cloud scheduling or GitHub Actions.
