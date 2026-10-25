# Exit contract under RAFT_COMPUTER_EXTERNAL_SUPERVISOR=1 (raft-source
# packages/computer/src/externalSupervisor.ts): 75 = relaunch me (restart or
# upgrade), 1 = crash; 77 = machine unlinked on the server, 78 = refused on
# configuration — those two must stay stopped. process-compose restarts on any
# non-zero exit, so map 77/78 to a clean exit here.
def --wrapped supervise [...args: string] {
  let code = try { ^raft-computer ...$args; 0 } catch {|e| $e.exit_code? | default 1 }
  if $code in [77 78] {
    print $"raft-computer stopped on purpose \(exit ($code)\); not restarting"
    exit 0
  }
  exit $code
}

if (^raft-computer status --json | from json | get servers | is-not-empty) {
  supervise start --foreground
}
let slug = ($env.RAFT_SERVER_SLUG? | default "")
if ($slug | is-not-empty) {
  supervise setup $slug --yes --foreground
}
print "not set up: set RAFT_SERVER_SLUG, or run `raft-computer setup /<slug> --yes --no-start` then `process-compose process start raft-computer`"
