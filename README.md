<p align="center"><img src="assets/logo.png" width="140" alt="gemma4-coding-kit logo"></p>

# gemma4-coding-kit

**A real 26B coding model that fits in your pocket-sized Mac. One command, and it's fixing bugs.**

```
curl -fsSL https://raw.githubusercontent.com/megasoft1978/gemma4-coding-kit/main/setup.sh | bash
```

Checks your hardware, downloads Gemma-4-26B-A4B (once), starts a correctly-tuned `llama-server`, configures the
[`pi`](https://github.com/earendil-works/pi) coding agent, and drops you straight into a session. No cloud API,
no account, nothing leaves your machine once the model's on disk.

## Why

The wider ecosystem assumes this model needs 24GB+. It doesn't. A smaller quant holds real quality at 16GB —
and every setting here (server flags, context window, prompt shape) comes from actually measuring that quant,
not guessing. This is a config and prompt package on top of `pi`, built from numbers, not a new agent.

<details>
<summary><strong>Advanced options</strong></summary>

Passing a flag through a pipe needs `bash -s --` (otherwise bash reads the flag itself):

```
curl -fsSL <raw-url>/setup.sh | bash -s -- --doctor          # diagnose an existing install, read-only
curl -fsSL <raw-url>/setup.sh | bash -s -- --start-only       # (re)start the server with the validated flags
curl -fsSL <raw-url>/setup.sh | bash -s -- --upgrade          # reapply the current config + restart the server
curl -fsSL <raw-url>/setup.sh | bash -s -- --report-speed     # measure real tokens/sec on a non-M1 chip
curl -fsSL <raw-url>/uninstall.sh | bash                      # remove everything
```

`--doctor` is the first thing to run if something's wrong. `setup.sh --help` and `uninstall.sh --help` list
every other flag.

**Requirements:** Apple Silicon Mac (M1/M2/M3/M4), 16GB unified memory or more, ~10GB free disk, and
[Homebrew](https://brew.sh) + [Node.js](https://nodejs.org) if you don't already have them. Rather not pipe a
script into `bash`? Read `setup.sh` first — one self-contained file, every command visible.

</details>

## Benchmarks

Bugs fixed across 9 realistic multi-file projects (React + Express + TypeScript), reported the way you'd
actually describe them to a coding agent: by symptom, never by cause. That's the number that matters, because
that's how people use one.

| Mode | Score |
|---|---|
| Single answer | **36/38 (95%)** |
| One self-correct retry (`--retry`) | **38/38 (100%)** |

The retry number isn't the shipped default — it's a second measurement. `pi` gets one shot per turn; this is
what happens if you show the model exactly which of its own checks still fail and let it take one more pass.
Both of this suite's remaining misses (below) are the model silently skipping a file it needed to touch — this
is exactly the kind of thing pointing it out, concretely, fixes.

Runs in about 10GB total: ~9.3GB of model weights on disk, plus ~1GB of working memory while the server runs.

| Chip | tokens/sec |
|---|---|
| M1 | **26.6 — measured** (mean across the full suite, shipped config) |
| M2 / M3 | ~39.1 — estimated |
| M2 Pro | ~78.2 — estimated |
| M3 Pro | ~58.7 — estimated |
| M1/M2/M3 Max | ~156.5 — estimated |
| M4 | ~46.9 — estimated |
| M4 Pro | ~106.8 — estimated |
| M4 Max | ~213.6 — estimated |

Non-M1 numbers are estimated from published memory bandwidth, not measured — run `--report-speed` to contribute
a real one. `setup.sh --benchmark` reproduces the score above on your own hardware (needs a full clone; the
scenario data doesn't fit in a single script).

<details>
<summary><strong>Levers measured</strong></summary>

| Config | Bugs fixed | tok/s | Verdict |
|---|---|---|---|
| Before the memory fix | ~27/30¹ | 22.3 | reference (4.9GB peak memory) |
| Memory fix, before the batch-size shrink | 36/38 | 24.4 | `--ctx-checkpoints 0 --cache-ram 0` — the memory growth was two llama-server bookkeeping defaults, not the KV cache (a fixed 780MB here). Turning them off costs nothing and drops peak memory to ~1GB. |
| **Shipped default** | **36/38** | **26.6** | Adds `-ub 256 -b 256` on top of the memory fix — a smaller prefill batch shrinks the remaining working buffer another ~6% (1023MB → 963MB peak, confirmed twice), same score, same-or-faster decode. |
| Optional recipe (not shipped) | 36/38 | 28.1 | Requantizing only the always-on attention/embedding tensors, leaving every expert untouched, cuts bytes read per token 10% for further speed on top of the shipped flags. Not the default because it produces a model file this kit doesn't host — see `optional/` in this repo if you want to build it yourself. |
| A smaller prefill batch still (`-ub 128 -b 128`) | 36/38 | — | ~4MB more memory saved — within noise. Not adopted; 256 is the floor. |
| A community speculative-decoding drafter | ~28/30¹ | 21.6 | 83% draft acceptance, still *slower* — on this model, verifying each drafted token costs its own expert lookup, so a better drafter doesn't help. Rejected. |
| Quantizing experts further too | ~25/30¹ | 21.6 | 3 more bugs lost for no speed gain — the experts are where this model's quality actually lives. Rejected. |
| A smaller pruned variant | ~23/30¹ | 21.5 | Fewer bytes, same speed, but answers ran 1.3–3.4× longer and one scenario hit the output-length ceiling before finishing. Rejected. |
| A stronger prompt demanding every file get touched | ~25/30¹ | — | Made things worse — broke a scenario (`realtime-sync`) that was already passing, on top of not fixing the two it targeted. Rejected. |
| Google's recommended sampling (temp 1.0/top_k 64/top_p 0.95) | ~27/30¹ | — | Worse than temperature 0 — a new, different bug fails than the usual near-tie. Rejected. |
| Top-nσ sampling (temp 1.0/top_nσ 1.0) | ~25/30¹ | — | Also worse than temperature 0. Rejected. |
| `max_tokens` 3072 → 4096 | 36/38 | — | No effect — byte-identical output. Truncation was never the limiter. Not adopted (no reason to). |
| A few-shot example in the prompt | ~26/30¹ | — | Worse — confirms this size of model can regress on few-shot even with a short, unrelated example. Rejected. |
| Alternative quant, bartowski IQ2_XXS | ~25/30¹ | — | Fixed one known miss, broke four others in `realtime-sync`. Rejected. |
| Alternative quant, mradermacher i1-IQ2_M | ~22/30¹ | — | Worse than the bartowski attempt too. This kit's quant beats both alternatives on this suite. Rejected. |

¹ Measured on the original 7-scenario/30-counted-bug suite, before `job-queue` and `permissions-cache` were
added — never re-run on the expanded suite since each was already rejected on its own terms.

Not perfectly lossless: at temperature 0, one bug flips depending on speculative decoding being on or off — a
real, deterministic side effect of batch-shape-dependent floating-point rounding, not noise.

</details>

<details>
<summary><strong>Every bug report, and every bug — pass, fail, and why</strong></summary>


Only 3 of the 9 scenarios have any failures on the shipped config or the optional recipe; the other 6
(`auth-session`, `cart-checkout`, `items-search`, `job-queue`, `notify-channel`, `permissions-cache`) score
100% on both and are omitted below for length. Each block below shows every bug in that scenario (not just the
failures), the wall-clock time, decode speed, and tokens generated, the exact prompt sent, and — where a retry
fired — the exact retry prompt and result.

<details>
<summary><code>api-versioning</code> — 6/6 shipped, 5/6 optional recipe</summary>

| | Shipped | Optional recipe |
|---|---|---|
| Time | 36.6s | 63.1s |
| Speed | 23.8 tok/s | 24.4 tok/s |
| Tokens generated | 741 | 1405 |

<details><summary>Exact prompt sent</summary>

````
You are fixing bugs in a Express + TypeScript app.

Bug reports from users:
We need to ship a v2 of the users endpoint at `/v2/users`, returning each user as
`{ id, firstName, lastName, email, createdAt }` — the full name split on the first space, with everything after
it as the last name, and a single-word name yielding an empty last name. v1 must keep returning exactly what it
returns today.

While you are in there, three existing problems have been reported:
1. Passing `?limit=abc` returns an empty list instead of rejecting the request or falling back to the default.
2. A caller can pass `?limit=100000` and pull the entire table in one request.
3. A negative offset (`?offset=-5`) returns duplicated rows.

Here are the relevant files:

=== README.md ===
```
# api-versioning

Public REST API.

- `server/routes/v1/users.ts` — the existing, frozen v1 endpoints. **v1 responses must not change.**
- `server/serializers.ts` — shared response shaping.
- `server/validate.ts` — shared input validation.

v1 returns a user as `{ id, name, email }`.
The v2 shape splits the name: `{ id, firstName, lastName, email, createdAt }`.
```

=== package.json ===
```
{ "name": "api-versioning", "private": true, "workspaces": ["server"] }
```

=== server/validate.ts ===
```
export interface Query {
  limit: number;
  offset: number;
}

export function parseQuery(raw: Record<string, unknown>): Query {
  const limit = parseInt(String(raw.limit ?? "20"), 10);
  const offset = parseInt(String(raw.offset ?? "0"), 10);
  return { limit, offset };
}
```

=== server/serializers.ts ===
```
export interface UserRow {
  id: number;
  full_name: string;
  email: string;
  created_at: string;
}

export function serializeV1(row: UserRow) {
  return { id: row.id, name: row.full_name, email: row.email };
}
```

=== server/routes/v1/users.ts ===
```
import { Router } from "express";
import { parseQuery } from "../../validate";
import { serializeV1, type UserRow } from "../../serializers";

const ROWS: UserRow[] = [
  { id: 1, full_name: "Ada Lovelace", email: "ada@example.com", created_at: "2026-01-02T00:00:00Z" },
  { id: 2, full_name: "Alan Turing", email: "alan@example.com", created_at: "2026-01-03T00:00:00Z" },
];

const router = Router();

router.get("/v1/users", (req, res) => {
  const { limit, offset } = parseQuery(req.query as Record<string, unknown>);
  const page = ROWS.slice(offset, offset + limit);
  res.json({ users: page.map(serializeV1) });
});

export default router;
```

Fix ALL the bugs. Output the complete corrected content of only the files you change, each as:

=== <path> ===
```
<full corrected file>
```

No explanation.
````
</details>

| Bug | What it tests | Shipped | Optional recipe |
|---|---|---|---|
| A | v2 route added | ✅ pass | ✅ pass |
| B | v2 serializer splits name correctly | ✅ pass | ❌ fail — none of 4 expected patterns found |
| C | v1 shape left untouched while v2 added | ✅ pass | ✅ pass |
| D | NaN limit falls back to default | ✅ pass | ✅ pass |
| E | limit capped | ✅ pass | ✅ pass |
| F | negative offset clamped | ✅ pass | ✅ pass |

</details>

<details>
<summary><code>orders-dashboard</code> — 4/5 shipped, 4/5 optional recipe</summary>

| | Shipped | Optional recipe |
|---|---|---|
| Time | 47.2s | 44.1s |
| Speed | 25.1 tok/s | 26.5 tok/s |
| Tokens generated | 878 | 854 |

<details><summary>Exact prompt sent</summary>

````
You are fixing bugs in a React + Express + TypeScript app.

Bug reports from users:
1. The orders table sometimes spins on "Loading…" forever and the network tab shows the request never
   completing normally — it happens when the backend hits an unexpected condition rather than on every request.
2. Order totals are occasionally wrong by a fraction of a cent — an order of 3 items at €0.10 shows as €0.30 in
   some places but the arithmetic drifts once more lines are added.
3. Orders placed late in the evening do not appear under "today" until the following morning.
4. A user reports they can see orders belonging to a different user.
5. Opening the orders page fires an endless stream of identical requests to /orders — the network tab never
   settles, and the UI re-renders continuously.


Here are the relevant files:

=== README.md ===
```
# orders-dashboard

Internal order browser.

- `server/` — Express + TypeScript API. Entry `server/index.ts`, routes in `server/routes/`,
  business logic in `server/services/`, middleware in `server/middleware/`.
- `client/` — React + TypeScript UI. `client/src/lib/` (api client), `hooks/`, `components/`.
- `shared/` — types shared by both sides.

Money is stored and returned in the API as a **decimal number of euros** (e.g. `12.30`).
```

=== package.json ===
```
{
  "name": "orders-dashboard",
  "private": true,
  "workspaces": ["client", "server", "shared"]
}
```

=== shared/types.ts ===
```
export interface OrderLine {
  sku: string;
  qty: number;
  unitPrice: number;
}

export interface Order {
  id: string;
  userId: string;
  placedAt: string; // ISO timestamp
  lines: OrderLine[];
  total: number;
}
```

=== server/index.ts ===
```
import express from "express";
import ordersRouter from "./routes/orders";
import { requireUser } from "./middleware/requireUser";
import { errorHandler } from "./middleware/errorHandler";

const app = express();
app.use(express.json());

app.use(ordersRouter);
app.use(requireUser);

app.use(errorHandler);

app.listen(3001, () => console.log("api on :3001"));

export default app;
```

=== server/middleware/requireUser.ts ===
```
import type { Request, Response, NextFunction } from "express";

declare global {
  namespace Express {
    interface Request {
      user?: { id: string };
    }
  }
}

// Attaches the authenticated user to the request. Every order query must be scoped to req.user.id.
export function requireUser(req: Request, res: Response, next: NextFunction) {
  const userId = req.header("x-user-id");
  if (!userId) {
    return res.status(401).json({ error: "unauthenticated" });
  }
  req.user = { id: userId };
  next();
}
```

=== server/middleware/errorHandler.ts ===
```
import type { Request, Response, NextFunction } from "express";

// eslint-disable-next-line @typescript-eslint/no-unused-vars
export function errorHandler(err: Error, _req: Request, res: Response, _next: NextFunction) {
  console.error(err);
  res.status(500).json({ error: "internal_error" });
}
```

=== server/services/orderService.ts ===
```
import type { Order } from "../../shared/types";

const ORDERS: Order[] = [
  { id: "o1", userId: "u1", placedAt: "2026-09-06T23:40:00.000Z", lines: [{ sku: "a", qty: 3, unitPrice: 0.1 }], total: 0 },
  { id: "o2", userId: "u2", placedAt: "2026-09-07T09:00:00.000Z", lines: [{ sku: "b", qty: 1, unitPrice: 12.3 }], total: 0 },
];

export function computeTotal(order: Order): number {
  let total = 0;
  for (const line of order.lines) {
    total += line.unitPrice * line.qty;
  }
  return total;
}

// Orders placed "today", in the operator's local timezone.
export function ordersPlacedToday(userId: string): Order[] {
  const today = new Date().toISOString().slice(0, 10);
  return ORDERS.filter((o) => o.userId === userId && o.placedAt.slice(0, 10) === today);
}

export async function loadOrders(userId: string): Promise<Order[]> {
  const rows = ORDERS.filter((o) => o.userId === userId);
  return rows.map((o) => ({ ...o, total: computeTotal(o) }));
}
```

=== server/routes/orders.ts ===
```
import { Router } from "express";
import { loadOrders, ordersPlacedToday } from "../services/orderService";

const router = Router();

router.get("/orders", async (req, res) => {
  const orders = await loadOrders(req.user!.id);
  res.json({ orders });
});

router.get("/orders/today", (req, res) => {
  res.json({ orders: ordersPlacedToday(req.user!.id) });
});

export default router;
```

=== client/src/lib/api.ts ===
```
import type { Order } from "../../../shared/types";

export async function fetchOrders(filter: { from?: string; to?: string }): Promise<Order[]> {
  const params = new URLSearchParams();
  if (filter.from) params.set("from", filter.from);
  if (filter.to) params.set("to", filter.to);
  const res = await fetch(`/orders?${params.toString()}`);
  const data = await res.json();
  return data.orders;
}
```

=== client/src/hooks/useOrders.ts ===
```
import { useEffect, useState } from "react";
import type { Order } from "../../../shared/types";
import { fetchOrders } from "../lib/api";

export function useOrders(filter: { from?: string; to?: string }) {
  const [orders, setOrders] = useState<Order[]>([]);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    setLoading(true);
    fetchOrders(filter)
      .then(setOrders)
      .finally(() => setLoading(false));
  }, [filter]);

  return { orders, loading };
}
```

=== client/src/components/OrderTable.tsx ===
```
import React from "react";
import { useOrders } from "../hooks/useOrders";

export function OrderTable({ from, to }: { from?: string; to?: string }) {
  const { orders, loading } = useOrders({ from, to });

  if (loading) return <p>Loading…</p>;

  return (
    <table>
      <tbody>
        {orders.map((o) => (
          <tr key={o.id}>
            <td>{o.id}</td>
            <td>{o.placedAt}</td>
            <td>€{o.total.toFixed(2)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
```

Fix ALL the bugs. Output the complete corrected content of only the files you change, each as:

=== <path> ===
```
<full corrected file>
```

No explanation.
````
</details>

| Bug | What it tests | Shipped | Optional recipe |
|---|---|---|---|
| A | async route errors never reach error handler | ❌ fail — file not found in output: server/routes/orders | ❌ fail — file not found in output: server/routes/orders |
| B | float money arithmetic | ✅ pass | ✅ pass |
| C | UTC vs local date boundary for 'today' | ✅ pass | ✅ pass |
| D | requireUser registered after routes (data leak) | ✅ pass | ✅ pass |
| E | unstable filter object causes infinite refetch | ✅ pass | ✅ pass |

**With one retry** (`bench.mjs --retry`):

- Time: 76.2s total · Speed (retry turn): 18.8 tok/s · Tokens generated: 1053 total

<details><summary>Exact retry prompt sent</summary>

```
That didn't fully fix it. These checks still fail:
- async route errors never reach error handler: still not fixed (file not found in output: server/routes/orders)

Output the complete corrected content of only the files that still need to change, in the same format as before (`=== <path> ===` then a fenced code block). No explanation.
```
</details>

Result: **5/5** — up from 4/5 before the retry.

</details>

<details>
<summary><code>realtime-sync</code> — 5/6 shipped, 5/6 optional recipe</summary>

| | Shipped | Optional recipe |
|---|---|---|
| Time | 65.6s | 58.6s |
| Speed | 19.3 tok/s | 20.9 tok/s |
| Tokens generated | 1108 | 1059 |

<details><summary>Exact prompt sent</summary>

````
You are fixing bugs in a React + Express + ws + TypeScript app.

Bug reports from users:
1. When two people have the document open, whoever made an edit sees their own edit appear twice.
2. If the connection drops and comes back, edits made while offline are lost — they never reach the server.
3. After a reconnect the app gets slower and slower, and eventually several duplicate messages arrive for a
   single edit.
4. Occasionally an edit is acknowledged but is missing from the document history after a server restart.
5. Two edits made in the same millisecond sometimes collide and one overwrites the other.
6. The socket keeps reconnecting even after the user navigates away from the document.

Here are the relevant files:

=== README.md ===
```
# realtime-sync

Live document sync.

- `server/` — Express + `ws`. Broadcast in `server/hub.ts`, persistence in `server/store.ts`.
- `client/` — React. Socket lifecycle in `client/src/sync/connection.ts`, outbound queue in
  `client/src/sync/queue.ts`, the hook in `client/src/sync/useSync.ts`.

Edits are queued locally, flushed to the server over a socket, and acknowledged by `opId`.
An edit is only removed from the queue once the server acknowledges it.
```

=== package.json ===
```
{ "name": "realtime-sync", "private": true, "workspaces": ["client", "server"] }
```

=== shared/types.ts ===
```
export interface Edit {
  opId: string;
  docId: string;
  at: number;
  patch: string;
}

export interface Ack {
  type: "ack";
  opId: string;
}
```

=== server/hub.ts ===
```
import type { WebSocket } from "ws";
import type { Edit } from "../shared/types";
import { persist } from "./store";

const clients = new Set<WebSocket>();

export function join(ws: WebSocket) {
  clients.add(ws);
  ws.on("close", () => clients.delete(ws));
}

export function broadcast(edit: Edit, from: WebSocket) {
  for (const c of clients) {
    c.send(JSON.stringify(edit));
  }
}

export async function handleEdit(ws: WebSocket, edit: Edit) {
  persist(edit);
  broadcast(edit, ws);
  ws.send(JSON.stringify({ type: "ack", opId: edit.opId }));
}
```

=== server/store.ts ===
```
import type { Edit } from "../shared/types";

const DOCS = new Map<string, Edit[]>();

export async function persist(edit: Edit): Promise<void> {
  const list = DOCS.get(edit.docId) ?? [];
  list.push(edit);
  DOCS.set(edit.docId, list);
}

export function history(docId: string): Edit[] {
  return DOCS.get(docId) ?? [];
}
```

=== client/src/sync/queue.ts ===
```
import type { Edit } from "../../../shared/types";

let pending: Edit[] = [];

export function enqueue(edit: Edit) {
  pending.push(edit);
}

export function acknowledge(opId: string) {
  pending = pending.filter((e) => e.opId !== opId);
}

export function drain(): Edit[] {
  const out = pending;
  pending = [];
  return out;
}

export function size(): number {
  return pending.length;
}
```

=== client/src/sync/connection.ts ===
```
import { drain } from "./queue";

let socket: WebSocket | null = null;

export function connect(url: string, onMessage: (data: unknown) => void) {
  socket = new WebSocket(url);

  socket.onopen = () => {
    for (const edit of drain()) {
      socket!.send(JSON.stringify(edit));
    }
  };

  socket.onmessage = (ev) => onMessage(JSON.parse(ev.data));

  socket.onclose = () => {
    setTimeout(() => connect(url, onMessage), 1000);
  };
}

export function send(edit: unknown) {
  socket?.send(JSON.stringify(edit));
}
```

=== client/src/sync/useSync.ts ===
```
import { useEffect, useState } from "react";
import type { Edit, Ack } from "../../../shared/types";
import { connect, send } from "./connection";
import { enqueue, acknowledge } from "./queue";

export function useSync(url: string, docId: string) {
  const [edits, setEdits] = useState<Edit[]>([]);

  useEffect(() => {
    connect(url, (msg) => {
      const m = msg as Edit | Ack;
      if ((m as Ack).type === "ack") {
        acknowledge((m as Ack).opId);
      } else {
        setEdits((prev) => [...prev, m as Edit]);
      }
    });
  }, [url]);

  function submit(patch: string) {
    const edit: Edit = { opId: String(Math.random()), docId, at: Date.now(), patch };
    enqueue(edit);
    send(edit);
  }

  return { edits, submit };
}
```

Fix ALL the bugs. Output the complete corrected content of only the files you change, each as:

=== <path> ===
```
<full corrected file>
```

No explanation.
````
</details>

| Bug | What it tests | Shipped | Optional recipe |
|---|---|---|---|
| A | broadcast echoes back to the sender | ✅ pass | ✅ pass |
| B | drain() empties the queue before send is confirmed | ❌ fail — file not found in output: client/src/sync/queue | ❌ fail — matched forbidden pattern: ^(?![\s\S]*(?:requeue\|pending\s*\.\s*unshift\|pending\s*=\s*\[\s*\.\.\.\s*\w+\s*,\s*\.\.\.\s*pending\|pending\s*=\s*\w+\s*\.\s*concat\s*\(\s*pending))[\s\S]*pending\s*=\s*\[\s*\] |
| C | reconnect stacks listeners / no backoff cap | ✅ pass | ✅ pass |
| D | persist not awaited before ack | ✅ pass | ✅ pass |
| E | opId from Math.random collides | ✅ pass | ✅ pass |
| F | no cleanup on unmount, reconnect loop continues | ✅ pass | ✅ pass |

**With one retry** (`bench.mjs --retry`):

- Time: 94.9s total · Speed (retry turn): 34.5 tok/s · Tokens generated: 1582 total

<details><summary>Exact retry prompt sent</summary>

```
That didn't fully fix it. These checks still fail:
- drain() empties the queue before send is confirmed: still not fixed (file not found in output: client/src/sync/queue)

Output the complete corrected content of only the files that still need to change, in the same format as before (`=== <path> ===` then a fenced code block). No explanation.
```
</details>

Result: **6/6** — up from 5/6 before the retry.

</details>

</details>
