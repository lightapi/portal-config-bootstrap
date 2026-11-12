# Diagnose a killed Portal View preparation process on RHEL

Use this guide when the shell prints only `Killed` for a command such as:

```bash
python3 -B scripts/portal-view-release.py --service portal-bff-sso prepare
```

The cause is not established by that message alone. A memory limit, an external
signal, or a host security policy can terminate a process. Successful execution
through a Python wrapper does not prove that a security agent killed the direct
invocation. Correlate the target host's evidence with its Linux administrator.

## Check the target checkout

Run these commands in an interactive Bash shell on the target server, using the
same deployment account and environment as the failing command:

```bash
cd /apps/portal-config-bootstrap
git status --short --branch
git rev-parse HEAD
python3 --version
```

Use your normal update procedure to obtain the merged diagnostics change
(PR #28). For a clean checkout already on `master`, this is:

```bash
git pull --ff-only origin master
```

Do not discard local deployment changes to update the checkout. Verify that the
CLI contains the tracing switch:

```bash
rg -n PORTAL_VIEW_TRACE scripts/portal-view-release.py
```

If `rg` is unavailable, use `grep -n PORTAL_VIEW_TRACE` with the same filename.

## Trace help before preparing anything

The help command does not download artifacts, stage releases, pull images, or
change release pointers. Start here if even `--help` is killed.

Create a private directory for this diagnostic session. Keep the same shell open
for the remaining commands so that `trace_dir` remains available:

```bash
trace_dir=$(mktemp -d "${TMPDIR:-/tmp}/portal-view-trace.XXXXXX")
echo "Diagnostic directory: $trace_dir"
date -Is
hostname

result=0
PORTAL_VIEW_TRACE=1 python3 -B scripts/portal-view-release.py \
  --help 2>"$trace_dir/help.log" || result=$?
echo "help exit=$result"

grep '^PORTAL_VIEW_TRACE:' "$trace_dir/help.log" | tail -n 30
```

`PORTAL_VIEW_TRACE=1` applies only to this invocation. Tracing is otherwise off;
it does not change the host security policy or bypass release validation.

A trace record looks like this (the PID and line number will differ):

```text
PORTAL_VIEW_TRACE: pid=12345 portal-view-release.py:120
```

Each record is written immediately before an executed line in the CLI or its
shared `portal_view_release.py` module. It contains no source text, variable
values, credentials, or subprocess arguments. Trace-output write failures disable
tracing rather than aborting the CLI.

## Interpret the result

| Observation | Meaning and next step |
| --- | --- |
| Help appears and exit is `0` | The direct invocation reached and completed the help path in this run. |
| `Killed` and exit is `137` | Consistent with SIGKILL; this does not identify the sender, reason, or point of termination. |
| The log is empty | No output reached the destination. Execution may have stopped before trace setup; an empty log alone does not identify a security rule. |
| Trace records stop at a particular line | That is the last script operation entered. It may be an import, function call, or subprocess call whose work continues elsewhere. It is not proof that the line itself caused the kill. |
| A normal Python or CLI error appears | Review that error locally and address it before retrying. |

Trace setup itself runs after the initial `sys` and `os` imports. No in-script
tracer can print before Python reaches that setup. Only the two release scripts
are traced; standard-library internals and child processes are not.

Match trace line numbers against the exact commit on the target. For example,
to inspect a small source range locally:

```bash
nl -ba scripts/portal-view-release.py | sed -n '115,125p'
```

Use `scripts/portal_view_release.py` instead if that is the traced filename.

## Trace preparation only when intended

If help works, and you intend to prepare the release, run:

```bash
result=0
PORTAL_VIEW_TRACE=1 python3 -B scripts/portal-view-release.py \
  --service portal-bff-sso prepare 2>"$trace_dir/prepare.log" || result=$?
echo "prepare exit=$result"

grep '^PORTAL_VIEW_TRACE:' "$trace_dir/prepare.log" | tail -n 30
```

Preparation can download and stage artifacts, pull the selected gateway image,
and set the first-release pointer after successful validation. It is not a
read-only diagnostic. It does not restart the serving gateway automatically.
Keep the same proxy settings and Docker/Podman adapter selection used for normal
preparation; do not change them just to collect this trace.

## Share evidence with the Linux administrator

Provide the hostname, deployment account, timestamp with time zone, checkout
commit, Python version, exact command, exit status, and last trace records. The
PID in those records helps correlate the process with host security/audit logs.

Review logs before sharing them. The files also capture **normal stderr**, which
can include URLs, command arguments, or configuration-related error details.
Only the `PORTAL_VIEW_TRACE:` records have the restricted format described above.
Do not paste `.env.bootstrap`, private keys, tokens, or complete configuration
files into a support conversation.

Ask the administrator to correlate kernel OOM/cgroup records, process signal
events where available, and endpoint security events at the test time. An account
without journal access cannot rule out a kernel event by seeing no results.
For example, an administrator can check:

```bash
sudo journalctl -k --since '30 minutes ago' --no-pager \
  | grep -Ei 'out of memory|oom|killed process|memory cgroup'
```

If the logs are inconclusive, an administrator-approved syscall trace may help
locate the last syscall or observed signal. It does not always identify the
killer and can capture sensitive process arguments; review that output privately.
Do not disable endpoint protection or SELinux to make the command run.
