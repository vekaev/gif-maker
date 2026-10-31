// Quick checks that run before every commit: the page's script parses, and every local file
// the page and the README point to exists. The full end-to-end suite runs before every push.
import { readFileSync, writeFileSync, existsSync, mkdtempSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..')
const html = readFileSync(path.join(root, 'index.html'), 'utf8')
let failed = false
const fail = (msg) => { console.error('✗ ' + msg); failed = true }

const scripts = [...html.matchAll(/<script type="module">([\s\S]*?)<\/script>/g)].map((m) => m[1])
if (scripts.length !== 1) fail(`expected one module script in index.html, found ${scripts.length}`)
const tmp = path.join(mkdtempSync(path.join(tmpdir(), 'gif-maker-')), 'page.mjs')
writeFileSync(tmp, scripts[0] ?? '')
try { execFileSync(process.execPath, ['--check', tmp], { stdio: 'pipe' }) }
catch (e) { fail('index.html script does not parse:\n' + e.stderr.toString()) }

const readme = readFileSync(path.join(root, 'README.md'), 'utf8')
const local = [...readme.matchAll(/(?:src|href)="([^"#:]+)"|\]\(([^)#:]+)\)/g)].map((m) => m[1] || m[2])
for (const ref of new Set(local)) if (!existsSync(path.join(root, ref))) fail(`README links to a missing file: ${ref}`)

for (const lib of html.matchAll(/https:\/\/cdn\.jsdelivr\.net\/npm\/([^'"\s]+)/g)) {
  if (!/@\d+\.\d+\.\d+\//.test(lib[1])) fail(`library URL must pin an exact version: ${lib[0]}`)
}

if (failed) process.exit(1)
console.log(`✓ index.html script parses, ${new Set(local).size} README files exist, CDN versions pinned`)
