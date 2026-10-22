// Reading the input: its shape from the first lines, a table lined up with spaces cut into its
// columns as the commands that print them line them up, and each record keeping the text it was
// read from.

import assert from "node:assert/strict";
import { test } from "node:test";

import { Reader, columnStarts, cutColumns, detect } from "../src/server/input.ts";
import type { Format, InputRecord } from "../src/server/input.ts";

/** Reads text as pickpen reads stdin, in pieces of `piece` characters. */
function read(text: string, format?: Format, piece = 7) {
  const out = {
    names: [] as string[],
    heading: undefined as string | undefined,
    records: [] as InputRecord[],
    problems: [] as string[],
  };
  const reader = new Reader(
    {
      columns(names, heading) {
        out.names = names;
        if (heading !== undefined) out.heading = heading;
      },
      record: (record) => out.records.push(record),
      problem: (text) => out.problems.push(text),
    },
    format,
  );
  for (let at = 0; at < text.length; at += piece) reader.feed(text.slice(at, at + piece));
  reader.end();
  return { ...out, format: reader.format, cells: out.records.map((r) => r.cells) };
}

const DOCKER = `CONTAINER ID   IMAGE          COMMAND                  CREATED        STATUS                    PORTS                    NAMES
4f1c2a9e7b3d   nginx:1.27     "/docker-entrypoint.…"   2 hours ago    Up 2 hours                0.0.0.0:8080->80/tcp     web
9a8b7c6d5e4f   postgres:16    "docker-entrypoint.s…"   3 days ago     Up 3 days (healthy)       5432/tcp                 db
1a2b3c4d5e6f   redis:7        "redis-server"           3 days ago     Exited (0) 2 hours ago                             cache
`;

const KUBECTL = `NAME                      READY   STATUS             RESTARTS       AGE
api-7d9f8b6c5d-2xkqp      1/1     Running            0              3d4h
api-7d9f8b6c5d-9hjzt      1/1     Running            2 (5h ago)     3d4h
worker-5c6b7d8f9-k2m4n    0/1     CrashLoopBackOff   14 (2m ago)    47m
`;

const DF = `Filesystem        Size    Used   Avail Capacity iused ifree %iused  Mounted on
/dev/disk3s1s1   926Gi    10Gi   612Gi     2%    426k  4.3G    0%   /
devfs            204Ki   204Ki     0Bi   100%     706     0  100%   /dev
/dev/disk3s6     926Gi    20Ki   612Gi     1%       0  6.4G    0%   /System/Volumes/VM
`;

const PS = `USER               PID  %CPU %MEM      VSZ    RSS   TT  STAT STARTED       TIME COMMAND
kalaomer         71234  12.3  1.1 412345678 182736   ??  S    10:01AM   1:02.33 /Applications/Safari.app/Contents/MacOS/Safari
root               123   0.0  0.0 408123456   1234   ??  Ss   Mon09AM   0:00.12 /usr/sbin/syslogd
_windowserver     1534   4.1  0.7 413456789 123456   ??  Ss   Mon09AM  52:10.45 /System/Library/WindowServer -daemon
`;

test("the shape is read from the first lines", () => {
  assert.equal(detect(DOCKER), "columns");
  assert.equal(detect(KUBECTL), "columns");
  assert.equal(detect(DF), "columns");
  assert.equal(detect(PS), "columns");
  assert.equal(
    detect(
      "COMMAND   PID  USER   FD   TYPE  DEVICE SIZE/OFF NODE NAME\nnode    12345 me   21u  IPv4 0x1a2b      0t0  TCP *:3000 (LISTEN)\n",
    ),
    "columns",
  );
  assert.equal(detect("/usr/bin/a /usr/lib\n/usr/bin/b /usr/lib\n"), "lines");
  assert.equal(detect("name,age\nann,3\nbob,4\n"), "csv");
  assert.equal(detect("name\tage\nann\t3\n"), "tsv");
  assert.equal(detect('{"a":1}\n{"a":2}\n'), "jsonl");
  assert.equal(detect('[{"a":1},\n{"a":2}]\n'), "json");
  assert.equal(detect('{\n  "items": []\n}\n'), "json");
  assert.equal(detect("a1b2c3d Fix the thing\n9f8e7d6 Add the other, and more\n"), "lines");
  assert.equal(detect("total 48\ndrwxr-xr-x  5 me staff 160 Oct 22 10:00 src\n"), "lines");
  assert.equal(detect("[2026-10-22 10:00:01] started\n[2026-10-22 10:00:02] ready\n"), "lines");
  assert.equal(detect("just one line\n"), "lines");
  assert.equal(detect(""), "lines");
});

test("docker's columns hold values with spaces of their own", () => {
  const { names, cells } = read(DOCKER);
  assert.deepEqual(names, [
    "CONTAINER ID",
    "IMAGE",
    "COMMAND",
    "CREATED",
    "STATUS",
    "PORTS",
    "NAMES",
  ]);
  assert.deepEqual(cells[0], [
    "4f1c2a9e7b3d",
    "nginx:1.27",
    '"/docker-entrypoint.…"',
    "2 hours ago",
    "Up 2 hours",
    "0.0.0.0:8080->80/tcp",
    "web",
  ]);
  assert.equal(cells[1]![4], "Up 3 days (healthy)");
  assert.deepEqual(cells[2]!.slice(4), ["Exited (0) 2 hours ago", "", "cache"]);
});

test("kubectl's restarts keep when they were", () => {
  const { names, cells } = read(KUBECTL);
  assert.deepEqual(names, ["NAME", "READY", "STATUS", "RESTARTS", "AGE"]);
  assert.deepEqual(cells[1], ["api-7d9f8b6c5d-9hjzt", "1/1", "Running", "2 (5h ago)", "3d4h"]);
  assert.deepEqual(cells[2], [
    "worker-5c6b7d8f9-k2m4n",
    "0/1",
    "CrashLoopBackOff",
    "14 (2m ago)",
    "47m",
  ]);
});

test("df's right-aligned numbers and its heading of two words", () => {
  const { names, cells } = read(DF);
  assert.deepEqual(names, [
    "Filesystem",
    "Size",
    "Used",
    "Avail",
    "Capacity",
    "iused",
    "ifree",
    "%iused",
    "Mounted on",
  ]);
  assert.deepEqual(cells[1], [
    "devfs",
    "204Ki",
    "204Ki",
    "0Bi",
    "100%",
    "706",
    "0",
    "100%",
    "/dev",
  ]);
  assert.equal(cells[2]![8], "/System/Volumes/VM");
});

test("ps's last column takes the rest of the line, spaces and all", () => {
  const { names, cells } = read(PS);
  assert.equal(names.at(-1), "COMMAND");
  assert.equal(names[1], "PID");
  assert.deepEqual(
    cells.map((c) => c[1]),
    ["71234", "123", "1534"],
  );
  assert.equal(cells[2]!.at(-1), "/System/Library/WindowServer -daemon");
  assert.equal(cells[0]![0], "kalaomer");
});

// As macOS prints it: a VSZ wider than its heading pushes the rest of the line to the right.
const PS_MAC = `USER               PID  %CPU %MEM      VSZ    RSS   TT  STAT STARTED      TIME COMMAND
_windowserver      394  45.9  1.0 104487033824 350624   ??  Rs   13Oct26 3046:43.05 /System/Library/WindowServer -daemon
someone          45283  39.3  0.5 1980409632 177600   ??  S    Wed12PM 738:52.90 /Applications/Dia.app/Contents/MacOS/Dia --type=renderer
root               123   0.0  0.0 408123456   1234   ??  Ss   Mon09AM   0:00.12 /usr/sbin/syslogd
`;

test("a table whose wide values push the line out of line is split at its spaces", () => {
  assert.equal(detect(PS_MAC), "columns");
  const { names, cells } = read(PS_MAC);
  assert.deepEqual(names, [
    "USER",
    "PID",
    "%CPU",
    "%MEM",
    "VSZ",
    "RSS",
    "TT",
    "STAT",
    "STARTED",
    "TIME",
    "COMMAND",
  ]);
  assert.deepEqual(cells[0], [
    "_windowserver",
    "394",
    "45.9",
    "1.0",
    "104487033824",
    "350624",
    "??",
    "Rs",
    "13Oct26",
    "3046:43.05",
    "/System/Library/WindowServer -daemon",
  ]);
  assert.equal(cells[1]![10], "/Applications/Dia.app/Contents/MacOS/Dia --type=renderer");
  assert.deepEqual(
    cells.map((c) => c[1]),
    ["394", "45283", "123"],
  );
});

test("a later line wider than the first ones is cut at the nearest space", () => {
  const starts = columnStarts("NAME    PID", ["ab      12"]);
  assert.deepEqual(starts, [0, 8]);
  assert.deepEqual(cutColumns("abcdefghij 1234", starts), ["abcdefghij", "1234"]);
  assert.deepEqual(cutColumns("ab    123456", starts), ["ab", "123456"]);
});

test("CSV keeps quoted commas and line breaks, and each record's own text", () => {
  const text = 'name,note\r\nann,"a, b"\r\nbob,"two\nlines"\ncat,"say ""hi"""\n';
  const { format, names, heading, cells, records } = read(text, undefined, 3);
  assert.equal(format, "csv");
  assert.deepEqual(names, ["name", "note"]);
  assert.equal(heading, "name,note");
  assert.deepEqual(cells, [
    ["ann", "a, b"],
    ["bob", "two\nlines"],
    ["cat", 'say "hi"'],
  ]);
  assert.deepEqual(
    records.map((r) => r.raw),
    ['ann,"a, b"', 'bob,"two\nlines"', 'cat,"say ""hi"""'],
  );
});

test("headings are made unique and never empty", () => {
  assert.deepEqual(read("a,,a,A\n1,2,3,4\n").names, ["a", "column 2", "a 2", "A 3"]);
});

test("JSON lines: keys are columns as they first come, a line that is not JSON is told", () => {
  const { format, names, cells, problems, records } = read(
    '{"a":1,"b":{"c":2}}\nnot json\n{"b":null,"d":true}\n',
  );
  assert.equal(format, "jsonl");
  assert.deepEqual(names, ["a", "b", "d"]);
  assert.deepEqual(cells, [
    ["1", '{"c":2}'],
    ["", "", "true"],
  ]);
  assert.deepEqual(problems, ["A line is not JSON"]);
  assert.deepEqual(records[1]!.value, { b: null, d: true });
});

test("a JSON document is its array, or the one array of objects it holds", () => {
  assert.deepEqual(read('[{"x":1},{"x":2}]').cells, [["1"], ["2"]]);
  const kube = read('{"apiVersion":"v1","items":[{"name":"a"},{"name":"b"}],"kind":"List"}');
  assert.deepEqual(kube.names, ["name"]);
  assert.deepEqual(kube.cells, [["a"], ["b"]]);
  assert.deepEqual(read("[1,2]").cells, [["1"], ["2"]]);
  const bad = read("[1, 2", "json");
  assert.deepEqual(bad.problems, ["The input is not one JSON document"]);
});

test("lines: blank ones skipped, colour codes and CR dropped", () => {
  const { format, names, records } = read("\x1b[32mone\x1b[0m\r\n\n  \ntwo\n");
  assert.equal(format, "lines");
  assert.deepEqual(names, ["line"]);
  assert.deepEqual(
    records.map((r) => r.raw),
    ["one", "two"],
  );
});

test("--input decides at once, so a slow first line is not waited on", () => {
  const rows: string[] = [];
  const reader = new Reader(
    { columns() {}, record: (r) => rows.push(r.raw), problem() {} },
    "lines",
  );
  reader.feed("first\n");
  assert.equal(reader.format, "lines");
  assert.deepEqual(rows, ["first"]);
});
