// Reads the same definitions used to generate the iPhone and StepX bindings.
import { readFileSync } from 'node:fs';
export const schema = JSON.parse(readFileSync(new URL('./agent_protocol/schema.json', import.meta.url), 'utf8'));
const defs = schema.$defs;
export class ProtocolError extends Error {}
const fail = code => { throw new ProtocolError(code); };
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const stringValue = value => { for (const char of value) { const point = char.codePointAt(0); if (point >= 0xd800 && point <= 0xdfff) fail('invalid_unicode'); } };

function check(s, value, path = '$') {
  if (s.$ref) return check(defs[s.$ref.replace('#/$defs/', '')], value, path);
  if (s.anyOf) {
    for (const option of s.anyOf) { try { check(option, value, path); return; } catch (error) { if (!(error instanceof ProtocolError)) throw error; } }
    fail(path + ':type');
  }
  if (s.const !== undefined && value !== s.const) fail(path + ':const');
  if (s.enum && !s.enum.includes(value)) fail(path + ':enum');
  if (s.type === 'null' && value !== null) fail(path + ':null');
  if (s.type === 'boolean' && typeof value !== 'boolean') fail(path + ':boolean');
  if (s.type === 'integer' && (!Number.isSafeInteger(value) || value < (s.minimum ?? -Infinity) || value > (s.maximum ?? Infinity))) fail(path + ':integer');
  if (s.type === 'string') {
    if (typeof value !== 'string' || [...value].length < (s.minLength ?? 0) || [...value].length > (s.maxLength ?? Infinity)) fail(path + ':string');
    stringValue(value);
    if (s.pattern && !new RegExp(s.pattern).test(value)) fail(path + ':pattern');
    if (s.format === 'date-time') {
      const match = /^(\d{4})-(\d{2})-(\d{2})T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)$/.exec(value);
      if (!match || !Number.isFinite(Date.parse(value))) fail(path + ':date-time');
      const y = Number(match[1]), m = Number(match[2]), d = Number(match[3]);
      const days = [31, (y % 4 === 0 && (y % 100 !== 0 || y % 400 === 0)) ? 29 : 28,31,30,31,30,31,31,30,31,30,31];
      if (y < 1 || m < 1 || m > 12 || d < 1 || d > days[m-1]) fail(path + ':date-time');
    }
  }
  if (s.type === 'array') {
    if (!Array.isArray(value) || value.length > (s.maxItems ?? Infinity)) fail(path + ':array');
    value.forEach((item, i) => check(s.items, item, `${path}[${i}]`));
  }
  if (s.type === 'object') {
    if (!object(value)) fail(path + ':object');
    const properties = s.properties ?? {};
    if ((s.required ?? []).some(key => !Object.hasOwn(value,key))) fail(path + ':required');
    if (s.additionalProperties === false && Object.keys(value).some(key => !Object.hasOwn(properties,key))) fail(path + ':unknown_field');
    for (const [key, item] of Object.entries(value)) {
      stringValue(key);
      if (Object.hasOwn(properties,key)) check(properties[key],item,path+'.'+key);
      else jsonValue(item);
    }
  }
}
function jsonValue(value, depth = 0) {
  if (depth > 64) fail('json_depth_exceeded');
  if (typeof value === 'string') { stringValue(value); return; }
  if (value === null || typeof value === 'boolean') return;
  if (typeof value === 'number' && Number.isFinite(value) && (!Number.isInteger(value) || Number.isSafeInteger(value))) return;
  if (Array.isArray(value)) { value.forEach(item => jsonValue(item, depth + 1)); return; }
  if (object(value)) { for (const [key,item] of Object.entries(value)) { stringValue(key); jsonValue(item, depth + 1); } return; }
  fail('invalid_json');
}
// Native JSON.parse keeps the last duplicate while Swift keeps the first.
// Scan key tokens before parsing; JSON.parse still owns syntax validation.
export function decode(name, raw) {
  if (typeof raw === 'string') stringValue(raw);
  const bytes = typeof raw === 'string' ? Buffer.from(raw, 'utf8') : raw;
  if (bytes.length > 1_048_576) fail('payload_too_large');
  let source;
  try { source = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes); } catch { fail('invalid_json_encoding'); }
  let at = 0;
  const space = () => { while (/[\x20\t\r\n]/.test(source[at] ?? '\0')) at++; };
  const token = () => {
    const start = at++;
    while (at < source.length) {
      const char = source[at++];
      if (char === '\\') { at++; continue; }
      if (char === '"') return source.slice(start, at);
    }
    fail('invalid_json_encoding');
  };
  const value = depth => {
    if (depth > 64) fail('json_depth_exceeded');
    space();
    const char = source[at];
    if (char === '"') { token(); return; }
    if (char === '{' || char === '[') {
      const isObject = char === '{', end = isObject ? '}' : ']', seen = new Set();
      at++; space();
      if (source[at] === end) { at++; return; }
      while (true) {
        if (isObject) {
          if (source[at] !== '"') fail('invalid_json_encoding');
          const key = JSON.parse(token()).normalize('NFC');
          stringValue(key);
          if (seen.has(key)) fail('duplicate_json_key');
          seen.add(key); space();
          if (source[at++] !== ':') fail('invalid_json_encoding');
        }
        value(depth + 1); space();
        if (source[at] === end) { at++; return; }
        if (source[at++] !== ',') fail('invalid_json_encoding');
        space();
      }
    }
    const start = at;
    while (at < source.length && !/[\x20\t\r\n,}\]]/.test(source[at])) at++;
    if (at === start) fail('invalid_json_encoding');
  };
  try {
    value(0); space();
    if (at !== source.length) fail('invalid_json_encoding');
    const result = JSON.parse(source);
    jsonValue(result);
    return validate(name,result);
  } catch (error) { if (error instanceof ProtocolError) throw error; fail('invalid_json_encoding'); }
}
export function validate(name,value) {
  if (!Object.hasOwn(defs,name)) fail('unknown_contract');
  check(defs[name],value);
  const authority = name === 'Authority' ? value : value?.authority;
  if (authority && (authority.phase === 'backend') !== (authority.epoch > 0)) fail('authority_epoch_mismatch');
  if (name === 'SourceSnapshot' && value.deleted && (value.text || Object.keys(value.attributes).length)) fail('tombstone_contains_content');
  if (['ExecutionRequest','ExecutionReceipt','CommandEnvelope','CommandReceipt','ContentReadRequest','ContentQueryRequest','ContentValidateRequest','CommandReceiptReadRequest'].includes(name) && authority.phase !== 'backend') fail('backend_authority_required');
  const target = name === 'CommandTarget' ? value : value?.target;
  if (target && (target.kind === 'source' ? target.source === null || target.entity_id !== null : target.source !== null || target.entity_id === null)) fail('invalid_command_target');
  if (name === 'CommandReceipt') {
    if (value.state === 'accepted' && (value.applied_revision === null || value.error !== null)) fail('accepted_revision_required');
    if (value.state !== 'accepted' && value.error === null) fail('command_error_required');
  }
  if (name === 'ExecutionReceipt') {
    if (['failed','unknown'].includes(value.state) && value.error === null) fail('execution_error_required');
    if (value.state === 'unknown' && value.error.retryable) fail('unknown_result_cannot_auto_retry');
    if (value.state === 'succeeded' && (value.error !== null || value.result === null && value.operation_id === null)) fail('success_requires_receipt');
  }
  return value;
}
