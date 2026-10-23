# Ruby stdio protocol notes

Ruby is the reference stdio client. The other language clients copy this.

Spawn `transport --stdio`. Put the websocket URL, including the api key, in `SELECTIVE_TRANSPORT_URL` on the child. Never put the URL or the key on argv. The child also inherits the rest of the parent environment.

If `SELECTIVE_TRANSPORT_URL` is set and non-empty, the first stdin line is a client message. The transport does not read the URL from stdin.

stdin and stdout are one JSON object per line. The line `exit` shuts the transport down and is not forwarded.

Let the child inherit stderr, or forward every line to your own stderr. Never only buffer it. A swallowed connect error becomes a bare retry failure.

Exit 0 after `exit`, stdin EOF, or a WebSocket close. Exit 1 if the process never connects. If the binary's `--help` does not list `--stdio`, fail immediately and name the legacy fallback. Do not retry an incompatible binary.

Do not send a client frame before `connected`. Queue earlier commands and apply them in order after `connected`. Wait 30 seconds, then exit 1.

While a batch runs, drain stdout only into a queue. Apply those commands in arrival order when the batch returns. Do not run two batches at once.

On stdout EOF, child death, or a dropped socket, raise connection-lost and reconnect outside the exception handler. Sleep min(attempt, 4) seconds. The 11th failure exits 1. Reconnect with `reconnect=true`. Keep the manifest and traces.

On SIGINT or SIGTERM, do not write the transport's stdin from the signal handler. That write deadlocks when a normal write holds the pipe, and the handler then exits without sending anything. Send `{"type":"terminating","data":{"signal":"INT"|"TERM"}}` from a context that can take the pipe, or rescue the failure. Either way, kill the transport and exit with the status of tests already finished. Write each frame with one call so a second writer cannot glue onto a half-written line. An integer `close.exit_status` already received is the status a later signal uses. `report_at_finish` and the test-map upload run on a normal close, not on this path.

Stdio creates no `/tmp` FIFOs. Put the child in its own process group so a group-wide SIGTERM reaches the runner first and `terminating` can be delivered.
