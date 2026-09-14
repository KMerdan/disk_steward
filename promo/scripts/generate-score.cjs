const fs = require('node:fs');
const path = require('node:path');

const sampleRate = 48000;
const seconds = 30;
const channels = 2;
const samples = sampleRate * seconds;
const pcm = Buffer.alloc(samples * channels * 2);
const accents = [3.3, 7.53, 14.7, 20.27, 26.83];

const smooth = (value) => value * value * (3 - 2 * value);
const pulse = (time, start, length) => {
  const local = time - start;
  if (local < 0 || local > length) return 0;
  return Math.sin(Math.PI * local / length) ** 2;
};

for (let i = 0; i < samples; i++) {
  const t = i / sampleRate;
  const intro = smooth(Math.min(1, t / 1.2));
  const outro = smooth(Math.min(1, (seconds - t) / 1.5));
  const bed =
    Math.sin(2 * Math.PI * 55 * t) * 0.12 +
    Math.sin(2 * Math.PI * 82.5 * t) * 0.07 +
    Math.sin(2 * Math.PI * 110 * t + Math.sin(t * 0.35)) * 0.035;
  const tick = pulse(t, Math.floor(t * 2) / 2, 0.055) * Math.sin(2 * Math.PI * 520 * t) * 0.045;
  let impact = 0;
  for (const at of accents) {
    const age = t - at;
    if (age >= 0 && age < 0.48) {
      impact += Math.exp(-age * 8) * (Math.sin(2 * Math.PI * 92 * age) * 0.16 + Math.sin(2 * Math.PI * 184 * age) * 0.06);
    }
  }
  const shimmer = Math.sin(2 * Math.PI * (220 + t * 1.7) * t) * 0.02 * pulse(t, 10.7, 15.3);
  const sample = Math.max(-1, Math.min(1, (bed + tick + impact + shimmer) * intro * outro));
  const left = Math.round(sample * 32767);
  const right = Math.round((sample * 0.96 + shimmer * 0.35) * 32767);
  pcm.writeInt16LE(left, i * 4);
  pcm.writeInt16LE(right, i * 4 + 2);
}

const header = Buffer.alloc(44);
header.write('RIFF', 0);
header.writeUInt32LE(36 + pcm.length, 4);
header.write('WAVE', 8);
header.write('fmt ', 12);
header.writeUInt32LE(16, 16);
header.writeUInt16LE(1, 20);
header.writeUInt16LE(channels, 22);
header.writeUInt32LE(sampleRate, 24);
header.writeUInt32LE(sampleRate * channels * 2, 28);
header.writeUInt16LE(channels * 2, 32);
header.writeUInt16LE(16, 34);
header.write('data', 36);
header.writeUInt32LE(pcm.length, 40);

const output = path.join(__dirname, '..', 'public', 'score.wav');
fs.writeFileSync(output, Buffer.concat([header, pcm]));
console.log(`Generated ${output} (${seconds}s, ${sampleRate} Hz, stereo)`);
