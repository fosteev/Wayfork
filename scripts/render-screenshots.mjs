#!/usr/bin/env node
// Renders the README screenshots (docs/screenshots/*.png) from the static HTML
// prototype boards in docs/design/prototype/. Every screenshot in the README is a
// render of a prototype board, never a capture of the live app — this script is
// the only thing that should ever write those PNGs.
//
// It drives a headless "Chrome for Testing" instance over the Chrome DevTools
// Protocol (no puppeteer, no npm deps — plain Node 22 with global fetch and
// WebSocket): for each shot it navigates to a prototype file, measures the
// target element's on-page rect, and asks Chrome to screenshot just that
// rect at 2x scale.
//
// Usage:
//   node scripts/render-screenshots.mjs            # render every shot below
//   node scripts/render-screenshots.mjs popover     # render only matching shot(s)
//
// The filter matches against the output file path (docs/screenshots/windows/tray.png)
// or its basename without extension (tray), so `windows` renders the whole
// docs/screenshots/windows/ set and `tray` renders just that one file.
//
// Chrome path can be overridden with WAYFORK_CHROME_PATH for other machines/versions.

import { spawn } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '..');
const PROTO_DIR = path.resolve(REPO_ROOT, 'docs/design/prototype');

const DEFAULT_CHROME_PATH =
  path.join(
    os.homedir(),
    '.cache/puppeteer/chrome/mac_arm-150.0.7871.24/chrome-mac-arm64',
    'Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing',
  );

const VIEWPORT = { width: 1600, height: 1200, deviceScaleFactor: 2 };

// The shot list: where each README screenshot comes from and what to clip to.
// Selectors pick the LIGHT copy of a board — every board holds a light and a
// dark side by side, so selectors are scoped to the `.t` wrapper that is not
// `.t.dark` wherever a board has both.
const SHOTS = [
  {
    file: 'docs/screenshots/popover.png',
    prototype: 'variant-c.html',
    selector: '#C1 .t:not(.dark) .pv',
  },
  {
    file: 'docs/screenshots/settings-tunnels.png',
    prototype: 'variant-c.html',
    selector: '#C3 .t:not(.dark) .win',
  },
  {
    file: 'docs/screenshots/settings-rules.png',
    prototype: 'variant-c.html',
    selector: '#C4 .win',
  },
  {
    file: 'docs/screenshots/logs-cant-reach.png',
    prototype: 'variant-c.html',
    selector: '#C8 .t:not(.dark) .win.lw',
  },
  {
    file: 'docs/screenshots/logs-connections.png',
    prototype: 'variant-c.html',
    selector: '#C9 .t:not(.dark) .win.lw',
  },
  {
    file: 'docs/screenshots/windows/tray.png',
    prototype: 'windows.html',
    selector: '#W9 .t:not(.dark) .pv',
  },
  {
    file: 'docs/screenshots/windows/tunnels.png',
    prototype: 'windows.html',
    selector: '#W11 .t:not(.dark) .win',
  },
  {
    file: 'docs/screenshots/windows/rules.png',
    prototype: 'windows.html',
    selector: '#W12 .win',
  },
  {
    file: 'docs/screenshots/windows/logs-connections.png',
    prototype: 'windows.html',
    selector: '#W17 .win',
  },
];

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function getFreePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.unref();
    srv.on('error', reject);
    srv.listen(0, '127.0.0.1', () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}

async function waitForDevTools(port, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/json/version`);
      if (res.ok) return;
    } catch {
      // Chrome not listening yet — retry.
    }
    await sleep(150);
  }
  throw new Error(`Chrome DevTools did not come up on port ${port} within ${timeoutMs}ms`);
}

class CDP {
  constructor(wsUrl) {
    this.ws = new WebSocket(wsUrl);
    this.nextId = 0;
    this.pending = new Map();
    this.eventWaiters = new Map();
    this.ws.addEventListener('message', (ev) => {
      const msg = JSON.parse(typeof ev.data === 'string' ? ev.data : ev.data.toString());
      if (msg.id !== undefined) {
        const p = this.pending.get(msg.id);
        if (!p) return;
        this.pending.delete(msg.id);
        if (msg.error) p.reject(new Error(msg.error.message));
        else p.resolve(msg.result);
      } else if (msg.method) {
        const waiters = this.eventWaiters.get(msg.method);
        if (waiters && waiters.length) waiters.shift().resolve(msg.params);
      }
    });
  }

  ready() {
    if (this.ws.readyState === WebSocket.OPEN) return Promise.resolve();
    return new Promise((resolve, reject) => {
      this.ws.addEventListener('open', () => resolve(), { once: true });
      this.ws.addEventListener('error', (e) => reject(new Error(String(e))), { once: true });
    });
  }

  send(method, params = {}) {
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }

  waitForEvent(method) {
    return new Promise((resolve) => {
      const arr = this.eventWaiters.get(method) ?? [];
      arr.push({ resolve });
      this.eventWaiters.set(method, arr);
    });
  }

  close() {
    this.ws.close();
  }
}

function rectExpression(selector) {
  // Scrolls the target into view, then returns its rect in page (not just
  // viewport) coordinates — captureBeyondViewport needs page coordinates,
  // and a board's `.win`/`.pv` can end up scrolled away from the origin.
  return `(() => {
    const el = document.querySelector(${JSON.stringify(selector)});
    if (!el) return null;
    el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    const r = el.getBoundingClientRect();
    return { x: r.x + window.scrollX, y: r.y + window.scrollY, width: r.width, height: r.height };
  })()`;
}

function matchesFilter(shot, filter) {
  if (!filter) return true;
  const base = path.basename(shot.file, '.png');
  return shot.file.includes(filter) || base === filter;
}

async function main() {
  const filter = process.argv[2];
  const shots = SHOTS.filter((s) => matchesFilter(s, filter));
  if (shots.length === 0) {
    console.error(`No shot matches "${filter}". Known files:\n${SHOTS.map((s) => `  ${s.file}`).join('\n')}`);
    process.exitCode = 1;
    return;
  }

  const chromePath = process.env.WAYFORK_CHROME_PATH || DEFAULT_CHROME_PATH;
  if (!fs.existsSync(chromePath)) {
    throw new Error(`Chrome for Testing not found at ${chromePath} (set WAYFORK_CHROME_PATH to override)`);
  }

  const port = await getFreePort();
  const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'wayfork-shots-'));
  const chrome = spawn(
    chromePath,
    [
      '--headless=new',
      `--remote-debugging-port=${port}`,
      '--no-first-run',
      '--no-default-browser-check',
      `--user-data-dir=${userDataDir}`,
    ],
    { stdio: 'ignore' },
  );

  let cdp;
  let failures = 0;
  try {
    await waitForDevTools(port);
    const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
    const target = list.find((t) => t.type === 'page');
    if (!target) throw new Error('No page target reported by Chrome DevTools');

    cdp = new CDP(target.webSocketDebuggerUrl);
    await cdp.ready();
    await cdp.send('Page.enable');
    await cdp.send('Emulation.setDeviceMetricsOverride', { ...VIEWPORT, mobile: false });

    let lastUrl;
    for (const shot of shots) {
      try {
        const fileUrl = 'file://' + path.join(PROTO_DIR, shot.prototype);
        if (fileUrl !== lastUrl) {
          const loaded = cdp.waitForEvent('Page.loadEventFired');
          await cdp.send('Page.navigate', { url: fileUrl });
          await loaded;
          lastUrl = fileUrl;
          await sleep(150); // let webfonts/layout settle
        }

        const evalResult = await cdp.send('Runtime.evaluate', {
          expression: rectExpression(shot.selector),
          returnByValue: true,
        });
        if (evalResult.exceptionDetails) {
          throw new Error(evalResult.exceptionDetails.exception?.description ?? 'evaluate failed');
        }
        const rect = evalResult.result.value;
        if (!rect) {
          throw new Error(`selector "${shot.selector}" matched nothing in ${shot.prototype}`);
        }

        // clip.scale multiplies on top of the page's own deviceScaleFactor (already
        // 2 from the emulation override above) — leave it at 1 or output comes out 4x.
        const { data } = await cdp.send('Page.captureScreenshot', {
          format: 'png',
          captureBeyondViewport: true,
          clip: { x: rect.x, y: rect.y, width: rect.width, height: rect.height, scale: 1 },
        });

        const outPath = path.resolve(REPO_ROOT, shot.file);
        fs.mkdirSync(path.dirname(outPath), { recursive: true });
        fs.writeFileSync(outPath, Buffer.from(data, 'base64'));
        console.log(
          `wrote ${shot.file} (${Math.round(rect.width * VIEWPORT.deviceScaleFactor)}x${Math.round(rect.height * VIEWPORT.deviceScaleFactor)})`,
        );
      } catch (err) {
        failures += 1;
        console.error(`FAILED ${shot.file}: ${err.message}`);
      }
    }
  } finally {
    cdp?.close();
    chrome.kill();
    // Chrome may still be flushing its profile for a moment after SIGTERM.
    await new Promise((resolve) => chrome.once('exit', resolve));
    fs.rmSync(userDataDir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }

  if (failures > 0) {
    process.exitCode = 1;
  }
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
