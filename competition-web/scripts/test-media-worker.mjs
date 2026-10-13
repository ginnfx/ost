import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { processClip } from './media-worker.mjs';

const root = await mkdtemp(join(process.cwd(), '.worker-test-'));
process.env.MEDIA_WORKER_TEMP_DIR = root;
const input = join(root, 'source.mp4');
const silent = join(root, 'silent.mp4');
const output = join(root, 'processed.m4a');
function run(args) {
  return new Promise((resolve, reject) => {
    const child = spawn('ffmpeg', args, { stdio: 'ignore' });
    child.on('error', reject);
    child.on('close', (code) => code === 0 ? resolve() : reject(new Error(`ffmpeg fixture generation failed: ${code}`)));
  });
}
try {
  await run(['-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=21', '-c:a', 'aac', '-b:a', '128k', '-y', input]);
  await run(['-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=black:s=64x64:d=21', '-an', '-c:v', 'mpeg4', '-y', silent]);
  const metadata = await processClip(input, output);
  assert.equal(metadata.audio_codec, 'aac');
  assert.equal(metadata.sample_rate, 48000);
  assert.equal(metadata.channels, 2);
  assert.equal(metadata.duration_mismatch, false);
  await assert.rejects(processClip(silent, join(root, 'rejected.m4a')), /audio_stream_missing/);
  process.stdout.write('Media worker: normalized transcode and silent-file rejection passed.\n');
} finally {
  await rm(root, { recursive: true, force: true });
}
