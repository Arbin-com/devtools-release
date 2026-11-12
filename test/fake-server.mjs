// Fake registry + fake GitHub API for the installer tests. No dependencies.
//
//   node test/fake-server.mjs            prints one JSON line {"port":N} once listening
//
// Environment:
//   FAKE_HOST          bind address (default 127.0.0.1)
//   FAKE_PORT          port (default 0 = pick one)
//   FAKE_ALT_HOST      host name used in the asset redirect (must differ from the host the client
//                      used, so a client that leaks the token to a redirect target is caught)
//   FAKE_VERSIONS      comma separated good versions (default 0.1.0,0.2.0,0.3.0,0.4.0)
//   FAKE_LATEST        content of unit-sim/latest (default: last of FAKE_VERSIONS)
//   FAKE_BAD_VERSION   a version whose manifest carries a wrong sha256 (default 0.9.0)
//   FAKE_WIN_EXE_DIR   directory holding unit-sim-<version>.exe for the win-x64 zips
//
// Endpoints:
//   GET /unit-sim/latest, /unit-sim/<v>/manifest.json   public index (counts any Authorization header)
//   GET /repos/Arbin-com/Others-develop/releases/assets/<id>
//         needs "Authorization: Bearer test-token" and "Accept: application/octet-stream"
//         (401 otherwise), answers 302 to /blob/<id> on the alternate host
//   GET /blob/<id>     the archive; counts any Authorization header
//   GET /__stats       {"indexAuthSeen":n,"blobAuthSeen":n,"assetCalls":n,"unauthorized":n,"log":[...]}
//   GET /__reset       zero the counters
import http from 'node:http';
import zlib from 'node:zlib';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const TOOL = 'unit-sim';
const OWNER = 'Arbin-com';
const REPO = 'Others-develop';
const TOKEN = 'test-token';
const PLATFORMS = ['win-x64', 'linux-x64', 'linux-arm64', 'osx-x64', 'osx-arm64'];

const host = process.env.FAKE_HOST || '127.0.0.1';
const versions = (process.env.FAKE_VERSIONS || '0.1.0,0.2.0,0.3.0,0.4.0').split(',');
const latest = process.env.FAKE_LATEST || versions[versions.length - 1];
const badVersion = process.env.FAKE_BAD_VERSION || '0.9.0';
const winExeDir = process.env.FAKE_WIN_EXE_DIR || '';

function octal(n, len) {
  return n.toString(8).padStart(len - 1, '0') + '\0';
}

// One-file ustar archive, gzip compressed.
function tarGz(name, content, mode) {
  const h = Buffer.alloc(512);
  h.write(name, 0, 'ascii');
  h.write(octal(mode, 8), 100, 'ascii');
  h.write(octal(0, 8), 108, 'ascii');
  h.write(octal(0, 8), 116, 'ascii');
  h.write(octal(content.length, 12), 124, 'ascii');
  h.write(octal(1700000000, 12), 136, 'ascii');
  h.write('        ', 148, 'ascii');
  h.write('0', 156, 'ascii');
  h.write('ustar\0', 257, 'ascii');
  h.write('00', 263, 'ascii');
  let sum = 0;
  for (const b of h) sum += b;
  h.write(octal(sum, 7).slice(0, 6) + '\0 ', 148, 'ascii');
  const pad = Buffer.alloc((512 - (content.length % 512)) % 512);
  return zlib.gzipSync(Buffer.concat([h, content, pad, Buffer.alloc(1024)]));
}

// One-file zip, stored (no compression).
function zipOne(name, content) {
  const n = Buffer.from(name, 'ascii');
  const crc = zlib.crc32(content);
  const local = Buffer.alloc(30);
  local.writeUInt32LE(0x04034b50, 0);
  local.writeUInt16LE(20, 4);
  local.writeUInt32LE(crc, 14);
  local.writeUInt32LE(content.length, 18);
  local.writeUInt32LE(content.length, 22);
  local.writeUInt16LE(n.length, 26);
  const central = Buffer.alloc(46);
  central.writeUInt32LE(0x02014b50, 0);
  central.writeUInt16LE(20, 4);
  central.writeUInt16LE(20, 6);
  central.writeUInt32LE(crc, 16);
  central.writeUInt32LE(content.length, 20);
  central.writeUInt32LE(content.length, 24);
  central.writeUInt16LE(n.length, 28);
  const localPart = Buffer.concat([local, n, content]);
  const centralPart = Buffer.concat([central, n]);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(1, 8);
  eocd.writeUInt16LE(1, 10);
  eocd.writeUInt32LE(centralPart.length, 12);
  eocd.writeUInt32LE(localPart.length, 16);
  return Buffer.concat([localPart, centralPart, eocd]);
}

function fakeScript(version) {
  return Buffer.from(
    `#!/bin/sh\ncase "\${1:-}" in\n  version) echo "${TOOL} ${version}" ;;\n  *) echo "${TOOL}: usage" >&2; exit 2 ;;\nesac\n`,
    'ascii',
  );
}

// ---- build all assets and manifests up front ---------------------------

const assets = new Map(); // id -> { buf, name }
const manifests = new Map(); // version -> json text
let nextId = 1000;

function build(version, wrongSha) {
  const platforms = {};
  for (const platform of PLATFORMS) {
    let buf = null;
    let ext = 'tar.gz';
    if (platform === 'win-x64') {
      ext = 'zip';
      const exe = path.join(winExeDir, `${TOOL}-${version}.exe`);
      if (winExeDir && fs.existsSync(exe)) buf = zipOne(`${TOOL}.exe`, fs.readFileSync(exe));
    } else {
      buf = tarGz(TOOL, fakeScript(version), 0o755);
    }
    const id = nextId++;
    const name = `${TOOL}-${version}-${platform}.${ext}`;
    if (buf) assets.set(id, { buf, name });
    const sha = buf ? crypto.createHash('sha256').update(buf).digest('hex') : '0'.repeat(64);
    platforms[platform] = {
      github_owner: OWNER,
      github_repo: REPO,
      github_tag: `${TOOL}@${version}`,
      github_asset: name,
      github_asset_api_url: `https://api.github.com/repos/${OWNER}/${REPO}/releases/assets/${id}`,
      sha256: wrongSha ? 'f'.repeat(64) : sha,
    };
  }
  manifests.set(
    version,
    JSON.stringify({ tool: TOOL, version, published: '2026-01-01T00:00:00Z', platforms }, null, 2) + '\n',
  );
}

for (const v of versions) build(v, false);
build(badVersion, true);

// ---- server ------------------------------------------------------------

const stats = { indexAuthSeen: 0, blobAuthSeen: 0, assetCalls: 0, unauthorized: 0, log: [] };

function send(res, code, body, type = 'text/plain') {
  res.writeHead(code, { 'Content-Type': type, 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  const p = url.pathname;
  const auth = req.headers['authorization'];
  stats.log.push(`${req.method} ${p}${auth ? ' [auth]' : ''}`);

  if (p === '/__stats') return send(res, 200, JSON.stringify(stats), 'application/json');
  if (p === '/__reset') {
    Object.assign(stats, { indexAuthSeen: 0, blobAuthSeen: 0, assetCalls: 0, unauthorized: 0, log: [] });
    return send(res, 200, 'ok');
  }

  if (p === `/${TOOL}/latest`) {
    if (auth) stats.indexAuthSeen++;
    return send(res, 200, latest + '\n');
  }
  let m = p.match(new RegExp(`^/${TOOL}/([^/]+)/manifest\\.json$`));
  if (m) {
    if (auth) stats.indexAuthSeen++;
    const text = manifests.get(m[1]);
    return text ? send(res, 200, text, 'application/json') : send(res, 404, 'not found');
  }

  m = p.match(new RegExp(`^/repos/${OWNER}/${REPO}/releases/assets/(\\d+)$`));
  if (m) {
    stats.assetCalls++;
    if (auth !== `Bearer ${TOKEN}`) {
      stats.unauthorized++;
      return send(res, 401, '{"message":"Bad credentials"}', 'application/json');
    }
    if (!String(req.headers['accept'] || '').includes('application/octet-stream')) {
      return send(res, 200, '{"note":"asset metadata, not the file"}', 'application/json');
    }
    if (!assets.has(Number(m[1]))) return send(res, 404, '{"message":"Not Found"}', 'application/json');
    const reqHost = (req.headers.host || '').replace(/:\d+$/, '');
    const port = server.address().port;
    const alt = process.env.FAKE_ALT_HOST || (reqHost === 'localhost' ? '127.0.0.1' : 'localhost');
    res.writeHead(302, { Location: `http://${alt}:${port}/blob/${m[1]}` });
    return res.end();
  }

  m = p.match(/^\/blob\/(\d+)$/);
  if (m) {
    if (auth) stats.blobAuthSeen++;
    const a = assets.get(Number(m[1]));
    if (!a) return send(res, 404, 'not found');
    res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': a.buf.length });
    return res.end(a.buf);
  }

  return send(res, 404, 'not found');
});

server.listen(Number(process.env.FAKE_PORT || 0), host, () => {
  console.log(JSON.stringify({ port: server.address().port }));
});
