import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const skill = process.env.AGENT_GUIDANCE_TEST_SKILL_DIR;
const windows = process.platform === 'win32';
const candidates = [
  { name: 'PowerShell', command: 'pwsh', args: ['-NoProfile', '-File', path.join(root, 'windows', 'Invoke-AgentGuidance.ps1')] },
  { name: 'Bash', command: windows ? path.join(process.env.ProgramFiles || 'C:/Program Files', 'Git', 'bin', 'bash.exe') : 'bash', args: [path.join(root, 'unix', 'agent-guidance.sh')] },
];
for (const shell of candidates) {
  const available = spawnSync(shell.command, ['--version'], { encoding: 'utf8' }).status === 0;
  test(`${shell.name}: initialization, registration, installation and protected generation`, { skip: !skill ? 'Set AGENT_GUIDANCE_TEST_SKILL_DIR to the standalone skill directory' : !available ? `${shell.name} unavailable` : false }, t => {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), 'guidance entry demo '));
    t.after(() => fs.rmSync(home, { recursive: true, force: true }));
    const invoke = (args, { explicit = true, ok = true, env = {} } = {}) => {
      const result = spawnSync(shell.command, [...shell.args, ...(explicit ? ['--skill-dir', skill] : []), ...args, '--home', home], {
        encoding: 'utf8', env: { ...process.env, CODEX_HOME: '', AGENT_GUIDANCE_SKILL_DIR: '', ...env },
      });
      if (ok) assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
      else assert.notEqual(result.status, 0);
      return result;
    };
    invoke(['preview'], { explicit: false, ok: false });
    assert.deepEqual(fs.readdirSync(home), []);
    invoke(['init']);
    const custom = path.join(home, '.agents', 'agents-md-setup.custom.md');
    const original = fs.readFileSync(custom);
    const destination = path.join(home, 'independent installed skill');
    const install = JSON.parse(invoke(['install', '--destination', destination, '--json']).stdout);
    assert.ok(!fs.existsSync(destination));
    invoke(['install', '--destination', destination, '--apply', '--review', install.review]);
    invoke(['init'], { explicit: false });
    assert.deepEqual(fs.readFileSync(custom), original);
    const preview = JSON.parse(invoke(['preview', '--json'], { explicit: false }).stdout);
    assert.ok(!fs.existsSync(path.join(home, '.codex')));
    invoke(['apply', '--review', 'stale'], { explicit: false, ok: false });
    assert.ok(!fs.existsSync(path.join(home, '.codex')));
    invoke(['apply', '--review', preview.review], { explicit: false });
    assert.equal(fs.readFileSync(path.join(home, '.claude', 'CLAUDE.md'), 'utf8'), '@~/.codex/AGENTS.md\n');
    assert.ok(JSON.parse(invoke(['preview', '--json'], { explicit: false }).stdout).files.every(file => !file.changed));
    const profile = path.join(home, 'codex profile with spaces');
    const env = { CODEX_HOME: profile };
    const moved = JSON.parse(invoke(['preview', '--json'], { explicit: false, env }).stdout);
    invoke(['apply', '--review', moved.review], { explicit: false, env });
    assert.ok(fs.existsSync(path.join(profile, 'AGENTS.md')));
    assert.equal(fs.readFileSync(path.join(home, '.claude', 'CLAUDE.md'), 'utf8'), '@' + path.join(profile, 'AGENTS.md').replaceAll('\\', '/').replaceAll(' ', '\\ ') + '\n');
    invoke(['preview'], { explicit: false, ok: false, env: { AGENT_GUIDANCE_SKILL_DIR: path.join(home, 'missing skill') } });
  });
}
