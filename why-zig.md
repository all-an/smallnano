# Why Zig

## Why smallnano uses Zig

smallnano is trying to be a cryptocurrency node that stays practical on a low-end computer, an older laptop, or a cheap VPS. That requirement shapes the implementation language as much as it shapes the protocol.

The reference implementation needs to be:

- explicit about memory use
- small in deployment footprint
- predictable under long uptime
- easy to audit in consensus-critical code
- comfortable around binary protocols, hashing, signatures, and SQLite
- realistic to ship as one simple native binary

Zig fits those goals better than the nearby alternatives.

## The core reason

The main power of Zig in this project is not just "it is fast" or "it has custom allocators".

The real advantage is this:

**Zig gives direct control over runtime behavior.**

That includes:

- where memory comes from
- how long memory lives
- which code paths allocate
- when allocation failure is handled
- how data is laid out in memory
- how external C code is linked and called
- what the final binary depends on

For a lightweight cryptocurrency node, that matters more than language aesthetics.

## Allocators are a major advantage

Yes, allocator control is one of Zig's biggest strengths here.

In Zig, allocators are explicit values passed through code instead of being hidden behind a language runtime. That makes it practical to choose different allocation strategies for different parts of the node.

Examples relevant to smallnano:

- networking buffers can use bounded reusable storage
- request parsing can use short-lived arena allocation
- persistent in-memory indexes can use a long-lived general allocator
- hot ledger paths can avoid allocation entirely
- startup and test code can use different allocators from long-running runtime code

This matters because smallnano is trying to hold a strict line on RAM usage. If allocations are hidden or globally managed by a runtime, it becomes harder to reason about steady-state memory behavior on weaker machines.

In Zig, the allocation story is visible in the API. That makes resource review much easier.

## No mandatory GC and no hidden runtime

smallnano is not a web app where a little runtime opacity is acceptable. It is consensus-sensitive software.

That means hidden behavior is expensive:

- hidden allocations complicate memory budgeting
- background runtime activity complicates latency reasoning
- runtime-managed lifetimes complicate auditability
- surprise pauses or growth complicate always-on node operation

Zig avoids this by not imposing:

- a garbage collector
- a mandatory runtime object model
- exception-style hidden control flow
- invisible heap allocation conventions

That helps keep the node closer to "what the code says is what the process does".

## Error handling is explicit

Cryptocurrency node code spends a lot of time in failure paths:

- malformed messages
- invalid signatures
- bad work
- broken storage state
- partial network input
- configuration mistakes
- interrupted startup and shutdown

Zig's error unions and `try`/`catch` model fit this well because error flow stays explicit and local. There is less temptation to treat failure as exceptional magic instead of a normal part of protocol software.

For smallnano, that is useful in:

- block validation
- database initialization
- bootstrap replay
- wallet unlock and seed handling
- message decode and framing

## Good fit for binary protocol work

smallnano spends a lot of time around fixed-size binary structures:

- state blocks
- votes
- message headers
- signatures
- hashes
- PoW fields

Zig is very good at this style of code because:

- integer widths are explicit
- endianness handling is direct
- slices and arrays are easy to reason about
- layout-sensitive code feels natural instead of awkward
- manual serialization is straightforward

That makes protocol code easier to inspect and less dependent on framework machinery.

## C interop matters more than it sounds

smallnano currently uses vendored SQLite and may continue to benefit from low-level libraries over time.

Zig's C interop is a real advantage here:

- easy to compile vendored C directly in the build
- no separate FFI ecosystem required
- low ceremony around bindings
- fewer moving parts in deployment

That is especially useful for a small, dependency-light node.

## Small binary, simple deployment

One of the practical goals of smallnano is operational simplicity:

- build a native binary
- move it to a machine
- run it

Zig aligns with that well:

- native binaries
- small runtime surface
- predictable external dependencies
- easy cross-compilation
- good fit for static or near-static deployment

This matters for low-end machines because operational complexity is also a decentralization cost.

## Why this matters specifically for smallnano

smallnano is not only trying to be correct. It is trying to be correct while staying lightweight.

That means the implementation language should support:

- strict memory budgets
- bounded data structures
- explicit queueing and backpressure
- lightweight startup
- easy review of consensus logic
- small packaging and release artifacts

Zig supports that style directly.

## Comparison with other languages

## Zig vs C

C can also achieve tiny binaries, explicit memory use, and direct low-level control.

Why not just use C:

- weaker safety defaults
- easier to make silent memory bugs
- more manual boilerplate in common tasks
- worse ergonomics for modern error handling
- easier to ship fragile code in consensus-critical paths

C is still closer to Zig than most languages in runtime model, but Zig gives much of the same control with a better safety and tooling story.

Short version:

- `C` matches the low-level model
- `Zig` keeps the same spirit but is a better engineering environment

## Zig vs Rust

Rust is the strongest serious alternative.

Rust advantages:

- stronger safety guarantees
- richer ecosystem
- mature library availability
- excellent correctness tooling

Why Zig still fits smallnano better:

- simpler runtime story
- easier to keep dependency surface small
- usually easier to keep binary shape and build graph minimal
- allocator-first style feels more direct
- less friction for low-level C-style systems work

Rust is better if the top priority is safety at scale in a large ecosystem.
Zig is better if the top priority is explicitness, minimalism, and a very lean node architecture.

Short version:

- `Rust` is the strongest alternative overall
- `Zig` is the cleaner fit for a very small, explicit node

## Zig vs Nim

Nim can get closer than many people think, especially with ARC or ORC instead of a traditional tracing GC.

Nim advantages:

- faster development
- more concise high-level syntax
- native compilation
- decent performance

Why Zig is still stronger for this project:

- fewer hidden runtime assumptions
- clearer allocation boundaries
- easier to reason about exact behavior
- better fit for consensus-critical low-level code

Nim can probably hit many of the resource goals if written carefully. It is just harder to be as confident that nothing subtle is happening outside the code you intended.

Short version:

- `Nim` is viable
- `Zig` is more predictable

## Zig vs Odin

Odin is more plausible for this kind of work than many higher-level languages because it is native, explicit, and systems-oriented.

Odin advantages:

- straightforward syntax
- low-level orientation
- explicit style
- decent performance potential

Why Zig still wins for smallnano:

- stronger fit for explicit allocator-driven design
- better cross-compilation and deployment story
- stronger C interop position
- more natural fit for small-binary, low-dependency distribution
- better match for "single lean node binary" goals

Odin could likely build a similar node. Zig is still the better match for a node whose identity is minimal footprint and very explicit runtime behavior.

## Zig vs D

D is powerful and can be made very efficient, especially in carefully written `@nogc` code.

D advantages:

- productive language
- strong systems programming capability
- can avoid GC on critical paths

Why Zig remains a better fit:

- no default GC model to work around
- smaller language/runtime surface
- less ambiguity about hidden behavior
- easier to keep the mental model simple

D is viable, but it requires more discipline to keep the runtime story as clean as Zig's by default.

## Zig vs Go

Go is extremely practical, but it is not the right shape for smallnano's implementation goals.

Go advantages:

- simple language
- fast compile times
- easy deployment
- good concurrency model

Why Zig is better here:

- no GC
- tighter memory control
- smaller runtime footprint
- easier to reason about long-lived low-resource behavior

Go is a good backend language. It is a weaker fit for a deliberately lean cryptocurrency node with explicit low-level resource budgets.

## Summary table

| Language | Can it hit the goals? | Main issue vs Zig |
|----------|------------------------|-------------------|
| C | Yes | Too easy to make dangerous mistakes |
| Rust | Yes | More build and dependency weight, heavier iteration |
| D | Mostly yes | More runtime complexity, GC model to manage around |
| Nim | Partially to mostly | More hidden behavior, weaker predictability |
| Odin | Probably yes | Less mature fit for this exact deployment model |
| Go | Partially | GC/runtime footprint works against the node goals |

## Why Zig is the right choice for smallnano

smallnano is trying to keep the full node cheap, understandable, and small.

Zig helps by making these things first-class:

- explicit memory control
- explicit failure handling
- predictable deployment
- low-level protocol clarity
- low dependency count
- easy auditing of hot paths

That does not mean Zig is perfect, or that other languages cannot work.

It means Zig is the best match for the combination of goals that define this project:

- a lightweight cryptocurrency node
- a small runtime footprint
- bounded resource use
- direct systems-level control
- practical operation on low-end hardware

For smallnano, that combination matters more than ecosystem size or syntax convenience. The implementation language should reinforce the protocol goal of decentralization through low operational cost.
