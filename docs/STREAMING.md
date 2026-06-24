# Streaming

Clementine has two streaming entry points. They differ in **who owns the run's
lifetime**, so picking the right one matters.

## Two modes

| | `Clementine.Loop.run_stream/3` | `Clementine.Agent.stream/2` |
|---|---|---|
| Ownership | Run-owned / server-owned | Consumer-owned |
| Execution | Synchronous, in the calling process | `Stream.resource` driven by the consumer |
| Delivery | Pushes each event to your callback | Emits events as the consumer iterates |
| If the consumer stops/dies | Run is unaffected | Run is canceled |
| Observers | Zero-or-more (fan out yourself) | One (the iterating consumer) |
| Best for | Durable / multi-observer streaming | Interactive sessions |

## When to use which

- **`Loop.run_stream/3`** — the ownership-neutral primitive. It runs in your
  process and pushes events to a callback; nothing ties the run to a consumer.
  Drive it yourself and broadcast events (e.g. via Phoenix PubSub) when you want
  durable execution that clients observe but don't control.

- **`Agent.stream/2`** — convenient for interactive use where one consumer
  drives the run and abandoning it should stop the work. The wrapping
  `Stream.resource` cancels the run if the consumer stops iterating or the
  agent goes down.

## Observe, don't own

For durable execution (e.g. an Oban-backed job that streams tokens to clients
which come and go), the consumer-owned model is wrong: a client disconnecting
must not cancel the run. Drive `Loop.run_stream/3` from the owning process and
fan its events out to zero-or-more observers. Clients then **observe** the
stream without **owning** its lifetime — they can attach and detach freely while
the run keeps going.
