import { spawn } from 'node:child_process';
import { chmod, copyFile, mkdtemp, mkdir, realpath, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';

const image = process.env.MEDIA_WORKER_IMAGE ?? 'ost-competition-media-worker:local';
const timeoutSeconds = Number(process.env.MEDIA_WORKER_TIMEOUT_SECONDS ?? '180');
const maxBytes = Number(process.env.MEDIA_MAX_UPLOAD_BYTES ?? `${500 * 1024 * 1024}`);

export async function processClip(inputPath, outputPath, normalize = false, limits = {}) {
  const maxUploadBytes = Math.min(Number(limits.maxUploadBytes ?? maxBytes), 500 * 1024 * 1024);
  const minClipSeconds = Number(limits.minClipSeconds ?? process.env.MEDIA_MIN_CLIP_SECONDS ?? 20);
  const maxClipSeconds = Number(limits.maxClipSeconds ?? process.env.MEDIA_MAX_CLIP_SECONDS ?? 360);
  const input = await realpath(inputPath);
  const output = resolve(outputPath);
  const inputInfo = await stat(input);
  if (!inputInfo.isFile() || inputInfo.size < 1 || inputInfo.size > maxUploadBytes) {
    throw new Error('Input file size is invalid.');
  }
  await mkdir(dirname(output), { recursive: true });
  const tempRoot = process.env.MEDIA_WORKER_TEMP_DIR ?? tmpdir();
  await mkdir(tempRoot, { recursive: true });
  const work = await mkdtemp(join(tempRoot, 'ost-media-'));
  await chmod(work, 0o777);
  const destination = join(work, 'processed.m4a');
  const args = [
    'run', '--rm', '--network=none', '--read-only', '--stop-timeout=2',
    '--memory=512m', '--memory-swap=512m', '--cpus=1', '--pids-limit=64',
    '--user=65532:65532', '--cap-drop=ALL', '--security-opt=no-new-privileges',
    '--tmpfs', '/tmp:rw,noexec,nosuid,size=64m',
    '--mount', `type=bind,src=${input},dst=/input/source,readonly`,
    '--mount', `type=bind,src=${work},dst=/output`,
    '-e', `MEDIA_MAX_UPLOAD_BYTES=${maxUploadBytes}`,
    '-e', `MEDIA_MIN_CLIP_SECONDS=${minClipSeconds}`,
    '-e', `MEDIA_MAX_CLIP_SECONDS=${maxClipSeconds}`,
    '-e', `MEDIA_WORKER_TIMEOUT_SECONDS=${timeoutSeconds}`,
    '--entrypoint', 'python3', image, '/app/process.py', '--input', '/input/source', '--output', '/output/processed.m4a',
    ...(normalize ? ['--normalize'] : []),
  ];
  try {
    const stdout = await new Promise((resolvePromise, reject) => {
      const child = spawn('docker', args, { stdio: ['ignore', 'pipe', 'pipe'] });
      const out = [];
      const err = [];
      let size = 0;
      const timer = setTimeout(() => child.kill('SIGKILL'), timeoutSeconds * 1000 + 10_000);
      child.stdout.on('data', (chunk) => {
        size += chunk.length;
        if (size > 16_384) child.kill('SIGKILL');
        else out.push(chunk);
      });
      child.stderr.on('data', (chunk) => err.push(chunk));
      child.on('error', reject);
      child.on('close', (code) => {
        clearTimeout(timer);
        const outputText = Buffer.concat(out).toString('utf8').trim();
        try {
          const result = JSON.parse(outputText);
          if (!result.ok) return reject(new Error(`Media processing rejected: ${result.code}.`));
          if (result.audio_codec !== 'aac' || result.sample_rate !== 48000 || result.channels !== 2 || result.duration_mismatch !== (Math.abs(result.original_seconds - result.audio_seconds) > 0.1)) {
            return reject(new Error('Media worker output did not match the required audio format.'));
          }
          if (code !== 0) return reject(new Error(`Media worker failed (${code ?? 'signal'}).`));
          resolvePromise(result);
        } catch (error) {
          if (error instanceof Error && error.message.startsWith('Media processing rejected:')) return reject(error);
          reject(new Error(`Media worker failed (${code ?? 'signal'}).`));
        }
      });
    });
    await copyFile(destination, output);
    return stdout;
  } finally {
    await rm(work, { recursive: true, force: true });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(new URL(import.meta.url).pathname)) {
  const [input, output, normalizeArg] = process.argv.slice(2);
  if (!input || !output) {
    console.error('Usage: node scripts/media-worker.mjs INPUT OUTPUT [--normalize]');
    process.exitCode = 64;
  } else {
    try {
      const metadata = await processClip(input, output, normalizeArg === '--normalize');
      process.stdout.write(`${JSON.stringify(metadata)}\n`);
    } catch (error) {
      process.stderr.write(`${error instanceof Error ? error.message : 'Media processing failed.'}\n`);
      process.exitCode = 1;
    }
  }
}
