// Writes the inputs of demo/: what `kubectl get pods`, `ps aux`, `git log --oneline`, a CSV
// export and a JSON-lines access log look like, made up, and the list of pickpen's own sources
// (for `--preview 'head {}'`), and the same on every run (a seeded
// generator), so that the harness and the screenshots show the same rows.
//
//   node tools/demo.mjs

import { mkdirSync, readdirSync, writeFileSync } from "node:fs";

let seed = 20261022;
function random() {
  seed = (seed * 1664525 + 1013904223) % 4294967296;
  return seed / 4294967296;
}
const pick = (items) => items[Math.floor(random() * items.length)];
const int = (low, high) => low + Math.floor(random() * (high - low + 1));
const id = (n, alphabet = "bcdfghjklmnpqrstvwxz2456789") =>
  Array.from({ length: n }, () => pick([...alphabet])).join("");
const pad = (text, width) => String(text).padEnd(width);
const right = (text, width) => String(text).padStart(width);

const root = new URL("../", import.meta.url);
const dir = new URL("demo/", root);
mkdirSync(dir, { recursive: true });
const write = (name, text) => writeFileSync(new URL(name, dir), text);

// ---- kubectl get pods --------------------------------------------------------------------

const apps = ["api", "web", "worker", "billing", "search", "auth", "mailer", "scheduler", "cache"];
const pods = [];
for (const app of apps) {
  const hash = id(10, "0123456789abcdef");
  for (let n = 0; n < int(2, 4); n++) {
    const roll = random();
    const status =
      roll < 0.74
        ? "Running"
        : roll < 0.84
          ? "CrashLoopBackOff"
          : roll < 0.9
            ? "Pending"
            : roll < 0.95
              ? "Error"
              : "Completed";
    const restarts =
      status === "CrashLoopBackOff"
        ? `${int(5, 40)} (${int(1, 9)}m ago)`
        : status === "Running" && random() < 0.3
          ? `${int(1, 3)} (${int(2, 20)}h ago)`
          : "0";
    const ready = status === "Running" ? "1/1" : "0/1";
    const age =
      status === "Pending"
        ? `${int(20, 90)}s`
        : random() < 0.5
          ? `${int(1, 9)}d${int(1, 23)}h`
          : `${int(2, 59)}m`;
    pods.push([`${app}-${hash}-${id(5)}`, ready, status, restarts, age]);
  }
}
write(
  "pods.txt",
  [["NAME", "READY", "STATUS", "RESTARTS", "AGE"], ...pods]
    .map(([name, ready, status, restarts, age]) =>
      `${pad(name, 34)}${pad(ready, 8)}${pad(status, 19)}${pad(restarts, 16)}${age}`.trimEnd(),
    )
    .join("\n") + "\n",
);

// ---- ps aux ------------------------------------------------------------------------------

const commands = [
  "/sbin/init",
  "/usr/lib/systemd/systemd-journald",
  "/usr/sbin/sshd -D",
  "sshd: deploy [priv]",
  "-bash",
  "node /srv/api/dist/server.js --port 8080",
  "node /srv/api/dist/worker.js --queue mail",
  "postgres: 16/main: checkpointer",
  "postgres: 16/main: walwriter",
  "postgres: app orders 10.0.0.12(53122) idle",
  "redis-server *:6379",
  "/usr/bin/dockerd -H fd://",
  "containerd --config /etc/containerd/config.toml",
  "nginx: master process /usr/sbin/nginx",
  "nginx: worker process",
  "python3 /opt/reports/nightly.py --since 2026-10-21",
  "/usr/bin/prometheus --config.file=/etc/prometheus.yml",
  "vim /etc/nginx/sites-enabled/app.conf",
  "tail -f /var/log/nginx/access.log",
  "cron -f",
];
const users = ["root", "deploy", "postgres", "www-data", "redis", "nobody"];
const ps = [
  `${pad("USER", 10)}${right("PID", 7)} ${right("%CPU", 4)} ${right("%MEM", 4)} ${right("VSZ", 8)} ${right("RSS", 7)} ${pad("TTY", 8)} ${pad("STAT", 4)} ${pad("START", 5)} ${right("TIME", 6)} COMMAND`,
];
let pid = 1;
for (const command of commands) {
  for (let n = 0; n < (command.includes("worker process") ? 4 : 1); n++) {
    const user =
      pid === 1
        ? "root"
        : command.startsWith("postgres")
          ? "postgres"
          : command.startsWith("nginx: worker")
            ? "www-data"
            : command.startsWith("redis")
              ? "redis"
              : pick(users.slice(0, 2));
    const cpu = (random() < 0.7 ? random() * 3 : random() * 80).toFixed(1);
    const mem = (random() * 12).toFixed(1);
    ps.push(
      `${pad(user, 10)}${right(pid, 7)} ${right(cpu, 4)} ${right(mem, 4)} ${right(int(4000, 2400000), 8)} ${right(int(800, 900000), 7)} ${pad(command === "-bash" || command.startsWith("vim") || command.startsWith("tail") ? "pts/0" : "?", 8)} ${pad(pick(["Ss", "S", "Sl", "R", "S<", "Ssl"]), 4)} ${pad(pick(["Oct20", "Oct21", "09:12", "11:40"]), 5)} ${right(`${int(0, 120)}:${String(int(0, 59)).padStart(2, "0")}`, 6)} ${command}`,
    );
    pid += int(3, 900);
  }
}
write("ps.txt", ps.join("\n") + "\n");

// ---- an access log, as JSON lines --------------------------------------------------------

const paths = [
  "/api/orders",
  "/api/orders/:id",
  "/api/users/me",
  "/api/search",
  "/api/cart",
  "/health",
  "/api/invoices",
  "/login",
  "/static/app.js",
];
const lines = [];
let time = Date.parse("2026-10-22T09:00:00Z");
for (let n = 0; n < 2400; n++) {
  time += int(50, 2500);
  const path = pick(paths).replace(":id", String(int(1000, 9999)));
  const slow = random() < 0.06;
  const ms = slow ? int(800, 4800) : Math.round(12 + random() ** 2 * 280);
  const status =
    random() < 0.035
      ? pick([500, 502, 503])
      : random() < 0.06
        ? pick([401, 404, 429])
        : path === "/login"
          ? 302
          : 200;
  const bytes = path.startsWith("/static")
    ? `${(random() * 400 + 80).toFixed(1)}KiB`
    : `${(random() * 18 + 0.2).toFixed(1)}KiB`;
  lines.push(
    JSON.stringify({
      time: new Date(time).toISOString(),
      level: status >= 500 ? "error" : status >= 400 ? "warn" : "info",
      method: path === "/login" || path === "/api/cart" ? pick(["POST", "GET"]) : "GET",
      path,
      status,
      ms,
      size: bytes,
      user: random() < 0.15 ? null : `u${int(100, 160)}`,
    }),
  );
}
write("requests.jsonl", lines.join("\n") + "\n");

// ---- a CSV export ------------------------------------------------------------------------

const regions = ["eu-west-1", "eu-central-1", "us-east-1", "ap-south-1"];
const roles = ["web", "api", "db", "cache", "queue", "batch"];
const csv = ["name,region,role,cpu,memory,disk,uptime,owner"];
for (let n = 1; n <= 64; n++) {
  const role = pick(roles);
  csv.push(
    [
      `${role}-${String(n).padStart(2, "0")}`,
      pick(regions),
      role,
      `${int(1, 97)}%`,
      `${(random() * 60 + 2).toFixed(1)}GiB`,
      `${int(20, 2000)}GiB`,
      `${int(0, 180)}d`,
      pick(["platform", "payments", "search", '"growth, emea"']),
    ].join(","),
  );
}
write("servers.csv", csv.join("\n") + "\n");

// ---- git log --oneline -------------------------------------------------------------------

const messages = [
  "Fix the order total when a coupon is applied twice",
  "Retry the payment provider's 503 once, after a second",
  "Keep the search index warm after a deploy",
  "Offer invoices as PDF from the account page",
  "Keep the session across a password change",
  "Report the queue's depth in the health check",
  "Merge the cart when the user signs in on another device",
  "Move the mailer's bounce handling to its own worker",
  "Drop the old export endpoint",
  "Tell the user which rows of an import failed, and why",
  "Read the currency from the account, not the browser",
  "Stop sending the welcome mail twice on a retried sign-up",
  "Cache the product page for a minute behind the CDN",
  "Show the refund's state on the order page",
  "Let support search orders by the last four digits",
  "Time out the search after two seconds and say so",
  "Add an index on orders(created_at, status)",
  "Bump the API's rate limit for partners to 600/min",
  "Write the nightly report to object storage",
  "Fix the time zone of the scheduled exports",
  "Keep the last 30 days of audit logs, not 7",
  "Rotate the signing key without logging everyone out",
  "Explain a declined card in words, not a code",
  "Batch the analytics events, 50 at a time",
  "Remove the feature flag for the new checkout",
  "Count a cancelled order once in the dashboard",
  "Lazy-load the images below the fold",
  "Fix the race between two refunds of one order",
  "Name the worker's queues after what they carry",
  "Release 2.14.0",
];
write("commits.txt", messages.map((m) => `${id(7, "0123456789abcdef")} ${m}`).join("\n") + "\n");

// ---- find . -name '*.ts' -------------------------------------------------------------------

const files = [];
const walk = (path) => {
  for (const entry of readdirSync(new URL(path, root), { withFileTypes: true })) {
    const child = `${path}${entry.name}`;
    if (entry.isDirectory()) walk(`${child}/`);
    else if (/\.(ts|tsx|css)$/.test(entry.name)) files.push(`./${child}`);
  }
};
walk("src/");
write("files.txt", files.sort().join("\n") + "\n");

console.log("wrote demo/: pods.txt ps.txt requests.jsonl servers.csv commits.txt files.txt");
