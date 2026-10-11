# Private AWS Instance Control Toolkit

## Summary

Create a private GitHub repository at `bobbymac/ec2-on-demand` containing a Bash-based AWS CLI utility for Linux and Windows through WSL. It will let the user select the VM's actual EC2 instance type, then manually start, stop, and inspect it from configured machines, while the current always-on machine runs weekly maintenance every Saturday at 3:00 AM America/Chicago.

Tailscale is required only for interactive SSH after startup. AWS CLI and Systems Manager handle starting, patching, and stopping the instance.

## Daily Workflow

1. On the local machine, run `./bin/ec2ctl --profile NAME sizes` to see supported instance types with RAM and vCPU counts. Run `start --choose` for an interactive size menu, `start --instance-type t3.xlarge` to request a specific type, or plain `start` to reuse the instance's current type.
2. Copy and run the printed `tailscale ssh rjm@aws.robertmccaleb.com` command to work on the instance. Starting the instance does not open SSH automatically.
3. Run `exit` to leave the SSH session and return to the local shell.
4. Run `./bin/ec2ctl --profile NAME stop` locally; the toolkit uses AWS CLI to stop the VM.

Exiting SSH leaves the instance running until the local stop command or scheduled maintenance shuts it down. There is no automatic runtime limit.

## Implementation Changes

- Add `bin/ec2ctl` with these commands:
  - `sizes`: List supported instance types starting at 4 GiB RAM, with type name, RAM, vCPU count, and a marker for the current type. Query AWS for specifications and offerings in the target instance's Availability Zone; do not treat an offered type as a guarantee of spare capacity.
  - `start [--instance-type TYPE | --choose]`: Optionally change the stopped instance to the selected type, start it, wait for EC2 health checks, and print `tailscale ssh rjm@aws.robertmccaleb.com`. Plain `start` uses its current type.
  - `stop`: Request a normal EC2 shutdown, retry within a finite deadline, and attempt a forced stop if normal shutdown does not complete. Wait for the stopped state with a finite timeout and return an error if shutdown cannot be confirmed.
  - `status`: Show EC2 state, launch time, instance type, Systems Manager availability, and the last locally recorded maintenance result.
  - `maintain`: Start if necessary, wait for Systems Manager, install all Ubuntu updates, capture output, reboot and verify health when required, and always attempt shutdown afterward—even if it was already running or an update or verification fails. Use the same normal-then-forced shutdown policy as `stop`.
  - `cost-audit`: Report persistent EBS storage, public or Elastic IPv4 addresses, and other obvious costs that remain while stopped.

- Store the AWS region and instance ID in a committed, non-secret configuration file. Select the correct instance during initial setup using `aws ec2 describe-instances`. Keep AWS access keys exclusively in the local AWS CLI profile under `~/.aws`; never copy credentials or `~/LEYS/AWS-RJM.pem` into Git.

- Implement size selection for the existing VM:
  - Select an actual EC2 type, which determines both RAM and CPU resources. Initial x86 examples are `t3.medium` (4 GiB), `t3.large` (8 GiB), `t3.xlarge` (16 GiB), `t3.2xlarge` (32 GiB), `m5.4xlarge` (64 GiB), and `m5.8xlarge` (128 GiB), subject to compatibility and offerings discovered during setup. Keep the supported list in non-secret configuration.
  - Validate the requested type against the supported list and live AWS metadata before mutation. Verify architecture, virtualization, boot-mode support, and attached-volume limits; verify required guest drivers during initial setup. Reject incompatible types rather than attempting an architecture migration or replacing the VM.
  - Change the type only when the instance is confirmed stopped. If a different type is requested while it is running or transitioning, return instructions to run `stop` first; do not interrupt a session automatically. Requesting the current type follows ordinary idempotent startup behavior.
  - Use AWS CLI `modify-instance-attribute` to apply the type and re-read the instance to confirm it before starting. Preserve the instance ID and attached EBS volumes, including their capacity and data; selecting VM size does not resize storage.
  - The selected type persists in AWS across stops and is visible from other configured computers. Both plain `start` and scheduled `maintain` reuse that type; maintenance never prompts for a size or silently switches to a cheaper type.
  - Require a terminal for `--choose`; cancellation makes no changes. Reject simultaneous `--choose` and `--instance-type`. Report resize or capacity errors without substituting another type. If resizing succeeds but startup fails, report the resulting type and state so the user can retry or choose another size.
  - Follow AWS guidance for [changing an EBS-backed instance type](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/change-instance-type-of-ebs-backed-instance.html) and [instance-type compatibility](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/resize-limitations.html).

- Provision least-privilege AWS access:
  - Scope start, stop, instance-attribute modification, and Systems Manager command execution to the selected instance wherever AWS supports resource-level permissions. Add the read-only describe actions needed for instance details, image compatibility, type specifications, and Availability Zone offerings; catalog actions that require wildcard resources do not grant mutation rights over other instances.
  - Attach a dedicated EC2 instance role using `AmazonSSMManagedInstanceCore`.
  - Verify or install and enable Systems Manager Agent once on Ubuntu.
  - Use Systems Manager `AWS-RunShellScript` to run noninteractive `apt-get update` followed by `apt-get dist-upgrade -y`, including safe handling of configuration-file prompts.
  - Stream the command output into the maintenance log and return a failure exit code when patching fails.
  - After successful updates, check whether Ubuntu requires a reboot. If so, reboot, confirm the reboot occurred, and wait for EC2 health checks and Systems Manager availability before final shutdown. Treat failed reboot verification as maintenance failure and still attempt shutdown.

- Add an installer for this local cron entry:
  - Run at `0 3 * * 6` in the host's America/Chicago timezone.
  - If the host misses the scheduled time, wait until the next Saturday. Do not automatically catch up; maintenance can still be invoked manually.
  - Use an absolute repository path and `flock` to prevent overlapping maintenance runs.
  - Write timestamped logs outside Git tracking.
  - Save the last maintenance result locally, including timestamps, update/reboot outcome, shutdown outcome, and log location. Expose it through `status`; on a machine with no local record, report that no local result is available. Do not add email or webhook notifications.
  - Stop the instance in a cleanup trap on success, package failure, timeout, or interruption.
  - Set finite timeouts for EC2 startup, Systems Manager registration, package installation, reboot verification, normal shutdown, and forced-stop verification. Preserve failure results even if cleanup succeeds.

- Initialize the empty directory as Git, add documentation and a strict `.gitignore`, scan the initial commit for keys and credentials, then create and push the private GitHub repository. Each additional computer needs:
  1. Access to the private GitHub repository.
  2. Linux or WSL with Bash and AWS CLI, using its own local profile and access keys.
  3. Tailscale only when interactive SSH is needed.
  4. The SSH key only if conventional SSH is used instead of Tailscale SSH.

- Document that stopping eliminates instance compute charges, but EBS volumes continue to incur storage charges. Public IPv4 and Elastic IP resources must also be audited.

## Interfaces and Safety

- Syntax: `./bin/ec2ctl [--profile NAME] {sizes|start [--instance-type TYPE | --choose]|stop|status|maintain|cost-audit}`.
- Commands are idempotent: starting an already-running instance and stopping an already-stopped instance succeed safely.
- The maintenance command always stops the instance afterward, per the selected policy. Its documentation will prominently warn not to use the instance during the Saturday maintenance window.
- Shutdown is always attempted, but AWS or connectivity failures can prevent completion. Record and prominently report an unconfirmed shutdown instead of claiming success. Forced shutdown is the selected fallback and can interrupt writes.
- Do not create automatic recovery snapshots before updates or add snapshot management in this version.
- No GitHub Actions or cloud scheduler will be added; the always-on local machine owns the weekly schedule.
- No private key, AWS credential, Tailscale credential, command output, or maintenance log may be committed.

## Test Plan

- Run ShellCheck and tests using a fake `aws` executable for stopped, pending, running, stopping, timeout, Systems Manager unavailable, patch-success, and patch-failure states.
- Test size listing, RAM/vCPU labels, current-type marking, explicit selection, interactive selection/cancellation, conflicting flags, and noninteractive menu rejection.
- Verify type changes occur only while stopped, are confirmed before startup, and preserve the instance ID and EBS volumes. Cover invalid or incompatible types, unavailable offerings, denied modification, failed confirmation, and insufficient startup capacity.
- Verify plain startup and maintenance retain the current AWS instance type, and a failed resize never starts the VM using an unintended type.
- Verify cleanup always requests a stop after maintenance, including when patching fails.
- Verify normal shutdown retries are bounded, forced stop is attempted only after normal shutdown fails to complete, and an unconfirmed forced stop produces an error.
- Test both reboot-required and no-reboot paths, including reboot failure, health-check timeout, and Systems Manager failing to return; verify cleanup still attempts shutdown.
- Verify concurrent maintenance is rejected by the lock.
- Verify local maintenance records distinguish update/reboot failure from shutdown failure, and `status` handles missing records. Confirm logs and records remain untracked.
- Verify the cron installer sets the Saturday schedule without catch-up behavior.
- Validate IAM permissions cannot start, stop, resize, or run commands on unrelated instances.
- With explicit authorization for live testing, perform an integration check of `status`, then a complete start, Systems Manager update, conditional reboot verification, and stop cycle and confirm the instance reaches `stopped`.
- Confirm fresh clones on Linux and WSL can run `status`, `start`, and `stop` without copying repository secrets. Verify `start` prints the SSH command and the user can exit SSH before stopping the instance locally.
- Include an explicitly authorized live resize of the stopped instance to a compatible type, verify health and existing files after startup, then stop it. Confirm another configured machine observes the selected type.

## Assumptions and Defaults

- The Tailscale node `aws.robertmccaleb.com` is the target EC2 instance.
- The exact EC2 instance ID, AWS region, Ubuntu login user, and Systems Manager status will be discovered during initial setup because they were not available locally.
- The key is `~/LEYS/AWS-RJM.pem`; its location is documented but never committed.
- "Update all packages" means refreshing APT metadata and installing the complete available upgrade set, not merely running `apt update`.
- Weekly maintenance runs Saturday at 3:00 AM America/Chicago, verifies a reboot when updates require one, and always attempts shutdown afterward using the forced-stop fallback when needed.
- The cron host is expected to remain powered on and connected at the scheduled time. Missed runs wait until the next scheduled Saturday.
- Maintenance reporting is local to the machine that ran it; results are not synchronized between computers.
- The current type stored in AWS is the default VM size. Size selection changes this existing instance in place and retains its storage; cross-architecture migration and automatic size changes are outside scope.
- Automatic snapshots, external notifications, native Windows/PowerShell support, and macOS support are outside this version's scope.
