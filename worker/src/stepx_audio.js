// StepX AAC-LC profile. Native iPhone/Watch WAV behavior is unchanged.
export function m4aInfo(bytes) {
  if (!(bytes instanceof Uint8Array) || bytes.length < 46 || bytes.length > 20 * 1024 * 1024) throw Error('invalid_m4a');
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const text = (at, n) => String.fromCharCode(...bytes.subarray(at, at + n));
  let count = 0;
  function boxes(start, end) {
    const result = [];
    while (start < end) {
      if (++count > 512 || end - start < 8) throw Error('invalid_m4a_boxes');
      let size = view.getUint32(start), header = 8;
      const type = text(start + 4, 4);
      // Android's muxer emits a 64-bit mdat even for small audio files.
      if (size === 1) {
        if (end - start < 16) throw Error('invalid_m4a_boxes');
        size = view.getUint32(start + 8) * 4294967296 + view.getUint32(start + 12); header = 16;
      }
      if (!Number.isSafeInteger(size) || size < header || size > end - start) throw Error('invalid_m4a_boxes');
      result.push({ type, start: start + header, end: start + size }); start += size;
    }
    return result;
  }
  function one(rows, type) {
    const selected = rows.filter(row => row.type === type);
    if (selected.length !== 1) throw Error('invalid_m4a_' + type);
    return selected[0];
  }
  const children = row => boxes(row.start, row.end);
  const top = boxes(0, bytes.length), ftyp = one(top, 'ftyp'), mdat = one(top, 'mdat');
  if (top[0] !== ftyp || ftyp.end - ftyp.start < 8 || mdat.end === mdat.start) throw Error('invalid_m4a_container');
  const moov = children(one(top, 'moov')), trak = children(one(moov, 'trak'));
  const mdia = children(one(trak, 'mdia')), mdhd = one(mdia, 'mdhd'), hdlr = one(mdia, 'hdlr');
  if (mdhd.end - mdhd.start < 24 || bytes[mdhd.start] !== 0
    || hdlr.end - hdlr.start < 12 || text(hdlr.start + 8, 4) !== 'soun') throw Error('invalid_m4a_track');
  const rate = view.getUint32(mdhd.start + 12), ticks = view.getUint32(mdhd.start + 16);
  if (rate !== 16000 || ticks < 1 || ticks / rate > 601) throw Error('invalid_m4a_duration');
  const stbl = children(one(children(one(mdia, 'minf')), 'stbl')), stsd = one(stbl, 'stsd');
  if (stsd.end - stsd.start < 8 || view.getUint32(stsd.start + 4) !== 1) throw Error('invalid_m4a_description');
  const entry = one(boxes(stsd.start + 8, stsd.end), 'mp4a');
  if (entry.end - entry.start < 28 || view.getUint16(entry.start + 8) !== 0
    || view.getUint16(entry.start + 16) !== 1 || view.getUint16(entry.start + 18) !== 16
    || view.getUint32(entry.start + 24) !== 16000 * 65536) throw Error('m4a_16k_mono_aac_required');
  const esds = one(boxes(entry.start + 28, entry.end), 'esds');
  function descriptor(at, end, tag) {
    if (at >= end || bytes[at++] !== tag) throw Error('invalid_m4a_codec');
    let size = 0, groups = 0, b;
    do {
      if (at >= end || ++groups > 4) throw Error('invalid_m4a_codec');
      b = bytes[at++]; size = size * 128 + (b & 127);
    } while (b & 128);
    if (size > end - at) throw Error('invalid_m4a_codec');
    return { start: at, end: at + size };
  }
  const es = descriptor(esds.start + 4, esds.end, 3);
  if (es.end - es.start < 3) throw Error('invalid_m4a_codec');
  let configAt = es.start + 3;
  const flags = bytes[es.start + 2];
  if (flags & 128) configAt += 2;
  if (flags & 64) { if (configAt >= es.end) throw Error('invalid_m4a_codec'); configAt += 1 + bytes[configAt]; }
  if (flags & 32) configAt += 2;
  const config = descriptor(configAt, es.end, 4);
  if (config.end - config.start < 13 || bytes[config.start] !== 0x40) throw Error('m4a_aac_lc_required');
  const specific = descriptor(config.start + 13, config.end, 5);
  if (specific.end - specific.start < 2 || bytes[specific.start] >>> 3 !== 2
    || ((bytes[specific.start] & 7) * 2 + (bytes[specific.start + 1] >>> 7)) !== 8
    || ((bytes[specific.start + 1] >>> 3) & 15) !== 1) throw Error('m4a_16k_mono_aac_lc_required');
  // Close the sample tables over the actual mdat. A plausible header alone is
  // not evidence of complete, decodable media or a billable duration.
  function table(row, width, base = 8) {
    if (row.end - row.start < base) throw Error('invalid_m4a_sample_table');
    const n = view.getUint32(row.start + base - 4);
    if (n < 1 || n > 16000 || row.end - row.start !== base + n * width) throw Error('invalid_m4a_sample_table');
    return n;
  }
  const timing = one(stbl, 'stts'), timingCount = table(timing, 8);
  let samples = 0, duration = 0;
  for (let i = 0; i < timingCount; i++) {
    const at = timing.start + 8 + i * 8, n = view.getUint32(at), delta = view.getUint32(at + 4);
    if (!n || !delta || delta > 4096) throw Error('invalid_m4a_timing');
    samples += n; duration += n * delta;
  }
  if (duration !== ticks || samples < 1 || samples > 16000) throw Error('invalid_m4a_timing');
  const sizes = one(stbl, 'stsz');
  if (sizes.end - sizes.start < 12 || view.getUint32(sizes.start + 8) !== samples) throw Error('invalid_m4a_sizes');
  const fixedSize = view.getUint32(sizes.start + 4);
  if (sizes.end - sizes.start !== 12 + (fixedSize ? 0 : samples * 4)) throw Error('invalid_m4a_sizes');
  const sampleSizes = Array.from({ length: samples }, (_, i) => fixedSize || view.getUint32(sizes.start + 12 + i * 4));
  if (sampleSizes.some(size => size < 4 || size > 65536)) throw Error('invalid_m4a_sizes');
  const offsets = stbl.filter(row => ['stco', 'co64'].includes(row.type));
  if (offsets.length !== 1) throw Error('invalid_m4a_offsets');
  const offset = offsets[0], wide = offset.type === 'co64', chunks = table(offset, wide ? 8 : 4);
  const map = one(stbl, 'stsc'), maps = table(map, 12), entries = [];
  for (let i = 0; i < maps; i++) {
    const at = map.start + 8 + i * 12, first = view.getUint32(at), n = view.getUint32(at + 4);
    if (first < 1 || first > chunks || !n || n > samples || view.getUint32(at + 8) !== 1
      || (i ? first <= entries[i - 1].first : first !== 1)) throw Error('invalid_m4a_chunks');
    entries.push({ first, n });
  }
  let sample = 0, entryIndex = 0, nextByte = mdat.start;
  for (let chunk = 1; chunk <= chunks; chunk++) {
    while (entryIndex + 1 < entries.length && entries[entryIndex + 1].first <= chunk) entryIndex++;
    const at = offset.start + 8 + (chunk - 1) * (wide ? 8 : 4);
    const position = wide ? view.getUint32(at) * 4294967296 + view.getUint32(at + 4) : view.getUint32(at);
    const n = entries[entryIndex].n;
    if (!Number.isSafeInteger(position) || position !== nextByte || sample + n > samples) throw Error('invalid_m4a_offsets');
    for (let i = 0; i < n; i++) nextByte += sampleSizes[sample++];
    if (nextByte > mdat.end) throw Error('invalid_m4a_truncated_media');
  }
  if (sample !== samples || nextByte !== mdat.end) throw Error('invalid_m4a_truncated_media');
  return { durationSec: ticks / rate, sampleRate: rate, channels: 1, format: 'm4a' };
}

export function m4aSourceSeconds(info, frames) {
  if (!Number.isSafeInteger(frames) || frames < 1 || frames > 16000 * 600
    || info.durationSec < frames / 16000 || info.durationSec - frames / 16000 > 0.256) throw Error('m4a_source_frames_mismatch');
  return frames / 16000;
}

export function storedStepXSeconds(object, key) {
  if (!object || !Number.isInteger(object.size)) return null;
  if (key.endsWith('.wav')) return object.size > 44 && (object.size - 44) % 2 === 0 ? (object.size - 44) / 32000 : null;
  const meta = object.customMetadata;
  const seconds = Number(meta?.sourceFrames) / 16000;
  return key.endsWith('.m4a') && object.size > 44 && meta?.audioFormat === 'm4a' && meta?.profile === 'apt.aac-lc-16k-mono/1'
    && Number.isSafeInteger(Number(meta.sourceFrames)) && seconds > 0 && seconds <= 600
    && meta.sha256 === key.slice(-68, -4) ? seconds : null;
}
