# smallnano To Fix

This list comes from the first real Docker devnet run.

## Current blockers

1. ✅ Done: fix peer address handling for local devnets.
   The current parser only accepts IP literals, so Docker service names like
   `node2:7276` are rejected. Decide whether to support hostnames explicitly or
   keep IP-only parsing and make the setup/docs enforce that clearly.

2. ✅ Done: stop the network worker from crashing on invalid peer entries.
   Invalid peers currently produce warnings and then hit a crash path in
   [src/network/network.zig](/Users/allanabrahao/Public/code/smallnano/src/network/network.zig:681).
   Bad peer data must fail safely, mark the peer as unusable, and return
   without destabilizing the node.

3. ✅ Done: clear or quarantine bad persisted peers safely.
   Once invalid peers are stored in SQLite, they keep coming back on restart.
   Startup should ignore, drop, or quarantine malformed persisted peers instead
   of reloading them into the live runtime.

4. ✅ Done: route RPC `send` through the node publish path.
   The current RPC handler processes the block directly in the local ledger.
   It should go through the node runtime publish API so local sends also trigger
   relay and election startup.

5. ✅ Done: route RPC `receive` through the node publish path.
   `receive` should follow the same node-owned path as `send`, not bypass the
   live runtime and consensus hooks.

6. Add a funded devnet distribution path.
   Fresh wallet accounts are derived correctly, but they are not opened or
   funded, so real transfers fail with `AccountNotOpen`. The dev/test workflow
   needs an honest way to move funds from the genesis supply into test wallets.

7. Persist wallet account indexes or restore them on startup.
   After restart, derived wallet accounts must be re-created manually before the
   wallet recognizes them again. Either persist the wallet account map or
   rebuild it deterministically from saved wallet metadata.

8. Add a real cross-node transaction test.
   Prove: unlock -> create/restore funded accounts -> send on node A ->
   propagation -> pending visible on node B -> receive on node B ->
   confirmation on all participating nodes.

9. Add a Docker devnet test flow that uses valid peer addresses.
   The local test harness should have a known-good configuration path so manual
   bring-up does not depend on guessing addresses or editing files by hand.

10. Update the setup page validation and UX.
    The setup page should reject unsupported peer formats before saving and
    explain what address forms are accepted for local Docker testing.

11. Investigate and fix the reported allocator leaks on shutdown.
    The logs show repeated `error(gpa)` leak reports during container restart.
    Those should be fixed before calling the runtime stable.

12. Re-run the three-node devnet after the fixes and record the results.
    Once the items above are fixed, repeat the Docker test and then update
    `test-net.md`, milestone status, and remaining roadmap items based on what
    actually passes.
